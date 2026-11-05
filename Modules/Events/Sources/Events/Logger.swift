import Foundation
import SwiftUI

/// Defines the severity level of an application log entry.
public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    /// Informational telemetry or standard operational success events.
    case info = "INFO"
    /// Detailed diagnostic information for development.
    case debug = "DEBUG"
    /// A non-critical issue that did not halt execution but requires attention.
    case warning = "WARN"
    /// A critical failure or severe application error.
    case error = "ERROR"
    
    public var id: String { self.rawValue }

    /// Ordering for the minimum-level gate: entries below `Logger.minimumLevel`'s severity
    /// are dropped. Debug is the lowest so the default gate changes nothing.
    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    // No `color` here, on purpose. Events is a leaf module that must not depend on Design, so a
    // level's color belongs to the module drawing it (the Activity Log's `LogLevel.semanticColor`).
    // Events owns only the level's identity, ordering and glyph.

    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .debug: return "ant.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Represents a single recorded event in the application's lifecycle.
public struct LogEntry: Identifiable, Sendable {
    /// A unique identifier for the entry.
    public let id: UUID
    /// The exact timestamp when the event occurred.
    public let timestamp: Date
    /// The severity classification of the event.
    public let level: LogLevel
    /// A detailed human-readable description of the event.
    public let message: String
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        // Collapse line breaks and other control characters to spaces so one entry is always one
        // line. Messages interpolate file names off disk, which may contain "\n", and a crafted
        // name could otherwise forge a second "[timestamp] [ERROR] …" line. Done here so every call
        // site is covered, as `SettingsManager.setCustomName` does. Not `.controlCharacters`, which
        // also takes Cf format characters (ZWJ, directional marks) that emoji and RTL names need.
        self.message = message.components(separatedBy: Self.lineBreakingChars).joined(separator: " ")
    }

    /// Characters that must not survive into a log message: C0/C1 controls (incl. tab and ESC —
    /// the latter blocks terminal-escape injection when the file is `cat`-ed) plus every Unicode
    /// line separator (U+0085 NEL, U+2028, U+2029). Deliberately excludes Cf format characters.
    private static let lineBreakingChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{0000}"..."\u{001F}")       // C0 controls (\n \r \t ESC …)
        set.insert("\u{007F}")                                             // DEL
        set.formUnion(CharacterSet(charactersIn: "\u{0080}"..."\u{009F}"))  // C1 controls
        set.formUnion(.newlines)                                           // + U+0085 / U+2028 / U+2029
        return set
    }()
    
    /// The one formatter that writes `~/sync-cloud.log`'s timestamps and reads them back, shared
    /// because `DateFormatter` is expensive to create. Locale and calendar are pinned (en_US_POSIX,
    /// Gregorian, as `LogGrouping.keyFormatter`) because it also parses: under, say, the Islamic
    /// calendar every parsed history line would be mis-dated. The zone is re-checked on every use;
    /// see ``LogTimestampFormatter``. Internal so `LogTimestampZoneTests` can drive the refresh
    /// without moving the process-wide `NSTimeZone.default`, which would race other suites.
    static let timestampFormatter = LogTimestampFormatter()

    /// The canonical single-line rendering (`[timestamp] [LEVEL] message`) used both for the disk
    /// log and for the Activity Log's Copy action, so the clipboard matches the file byte-for-byte.
    public var formattedString: String {
        return "[\(Self.timestampFormatter.string(from: timestamp))] [\(level.rawValue)] \(message)"
    }

    /// The inverse of ``formattedString``, so the Activity Log can show history from
    /// `~/sync-cloud.log` older than this session. Nil for any line not in the exact
    /// `[timestamp] [LEVEL] ` shape (blank, or cut by a trim), so a malformed line is skipped.
    /// Splits on the first `] [` and `] ` only, so a message that embeds them (a crafted name)
    /// stays wholly in `message` and can't forge a second entry.
    public nonisolated static func parse(_ line: String) -> LogEntry? {
        guard line.hasPrefix("["),
              let tsClose = line.range(of: "] ["),
              let levelClose = line.range(of: "] ", range: tsClose.upperBound..<line.endIndex) else {
            return nil
        }
        let timestampText = String(line[line.index(after: line.startIndex)..<tsClose.lowerBound])
        let levelText = String(line[tsClose.upperBound..<levelClose.lowerBound])
        let message = String(line[levelClose.upperBound...])
        guard let level = LogLevel(rawValue: levelText),
              let timestamp = timestampFormatter.date(from: timestampText) else {
            return nil
        }
        return LogEntry(timestamp: timestamp, level: level, message: message)
    }

    /// The developer-oriented `" | Location: file:line / function"` tail that `warning`/`error`
    /// append, split from the human-readable message. The Activity Log shows `body` prominently and
    /// `location` as a dimmed caption, so a warning row reads as its message, not as a file path.
    public var messageBody: String { messageSplit.body }
    public var messageLocation: String? { messageSplit.location }
    private var messageSplit: (body: String, location: String?) {
        // Only warning and error carry the tail, so info and debug show whole even if a file name
        // contains " | Location: ". Split on the last occurrence, since the real tail is always
        // last, so any user-authored one stays in the body.
        guard level == .warning || level == .error,
              let range = message.range(of: " | Location: ", options: .backwards) else { return (message, nil) }
        return (String(message[..<range.lowerBound]), String(message[range.upperBound...]))
    }
}

/// The `~/sync-cloud.log` timestamp, rendered and parsed through one lock-guarded formatter.
///
/// The zone is re-checked on every use, not captured: a `DateFormatter` with no `timeZone` keeps
/// the zone it first formatted in, so after a zone change every later line would carry the wrong
/// wall clock, permanently. The same remedy as `Design.ZoneRefreshedFormatter`, not that type,
/// because Events must not depend on Design. The file is a sequence of wall-clock readings, each
/// in the zone current when it was written; it already spans zones, since it outlives sessions.
///
/// Rendering and parsing must share a zone: the Activity Log parses a line and renders it back
/// (`LogEntryRow` re-checks too), so a line displays as its text only while the two agree.
///
/// Accepted cost: `LogViewer.parseOlderThan` compares instants with `sessionStart`, so after a
/// mid-session zone change "Show older history" can show a few of this session's lines twice or
/// hide a few of the last session's, until the next launch. Stamping a UTC offset in every line
/// would fix it, at the price of an on-disk format change.
///
/// Locked because `Logger.log` is `nonisolated`, so many threads format at once, and writing
/// `timeZone` while another thread formats is unsafe. The same `NSLock` shape as
/// `MinimumLevelBox`. (DST is not this question; a `TimeZone` handles its own transitions.)
final class LogTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Renders one canonical timestamp, in the zone the system is in now.
    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        refreshZone()
        return formatter.string(from: date)
    }

    /// Reads one canonical timestamp back, in the zone the system is in now — the same zone
    /// ``string(from:)`` just wrote in, which is the pairing the round trip depends on.
    func date(from text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        refreshZone()
        return formatter.date(from: text)
    }

    /// Callers must hold `lock`. The compare is cheap and the assignment only runs when the zone
    /// has actually moved.
    private func refreshZone() {
        if formatter.timeZone != TimeZone.current { formatter.timeZone = TimeZone.current }
    }

    /// The zone the formatter is on now. A test seam, so `LogTimestampZoneTests` can observe the
    /// refresh without moving the process-wide `NSTimeZone.default`.
    var zone: TimeZone {
        lock.lock()
        defer { lock.unlock() }
        return formatter.timeZone
    }

    /// Puts the shared formatter on `zone` without refreshing, so a test can stage the stale state
    /// this class exists to prevent. Test-only: nothing in the app calls it.
    func stageZoneForTesting(_ zone: TimeZone) {
        lock.lock()
        formatter.timeZone = zone
        lock.unlock()
    }
}

/// The app's thread-safe logging service: writes `~/sync-cloud.log` and keeps an observable
/// history for the Activity Log.
@MainActor
public class Logger: ObservableObject {
    /// The shared instance. `nonisolated` because every logging entry point is already
    /// `nonisolated` and hands off through the FIFO buffer, so background work needn't hop to the
    /// main actor just to reach it. The `@MainActor` members still require `await`.
    public nonisolated static let shared = Logger(logFileURL: Logger.defaultLogFileURL())

    /// The active memory cache of recent log entries presented in the UI.
    @Published public var entries: [LogEntry] = []

    /// When this session started, where the Activity Log's "Show older history" divides entries.
    /// A fixed value, not `entries.first`: the cache keeps only the newest entries, so after a busy
    /// session `entries.first` would file this session's lines under "Earlier sessions".
    public let sessionStart = Date()

    /// The absolute disk URL mapping to the destination log file. Public so Settings can
    /// reveal it in Finder and show its size next to the Clear Log control.
    public let logFileURL: URL

    /// Defaults key holding the persisted minimum level (a `LogLevel` raw value). The app
    /// seeds `shared.minimumLevel` from it at launch; Settings writes both.
    public nonisolated static let minimumLevelDefaultsKey = "logMinimumLevel"

    /// True when this process is a test runner: `swift test`'s `swiftpm-testing-helper` (which
    /// links no XCTest) or `xctest` runner, or Xcode's XCTest* environment markers. Shared by
    /// ``defaultLogFileURL()`` and ``persistedMinimumLevel(from:)``.
    public nonisolated static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
        return executable == "swiftpm-testing-helper"
            || executable == "xctest"
            || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// The persisted minimum level, or `.debug` (log everything) when unset or unrecognized.
    ///
    /// Under a test runner the ambient value is never read and this is `.debug`: app-target tests
    /// run inside SyncCloud.app, so `.standard` is the owner's live preferences, and a raised level
    /// there would drop the `debug` lines many suites assert on. Same rule as
    /// ``defaultLogFileURL()``: a test host must not inherit the machine's user-facing state. An
    /// explicit suite passed as `from:` is still read, so the Settings UI stays testable.
    public nonisolated static func persistedMinimumLevel(from defaults: UserDefaults = .standard) -> LogLevel {
        persistedMinimumLevel(from: defaults, ambient: .standard)
    }

    /// The rule above with the ambient store named, so a test can use a scratch suite instead of
    /// the standard domain, which under `swift test` is one plist shared by every test process.
    nonisolated static func persistedMinimumLevel(from defaults: UserDefaults, ambient: UserDefaults) -> LogLevel {
        if isRunningTests, defaults == ambient { return .debug }
        return defaults.string(forKey: minimumLevelDefaultsKey).flatMap(LogLevel.init(rawValue:)) ?? .debug
    }

    /// Entries below this severity are dropped before they reach memory or disk. Nonisolated
    /// (lock-guarded) because `log()` runs on the caller's thread.
    public nonisolated var minimumLevel: LogLevel {
        get { minimumLevelBox.get() }
        set { minimumLevelBox.set(newValue) }
    }
    private let minimumLevelBox = MinimumLevelBox()


    /// Serializes writes to the log file on a background queue while keeping a single file handle
    /// open, avoiding a per-line open/seek/close cycle. Internal (not private) so tests can
    /// `flush()` before asserting on file contents.
    let logWriter: LogFileWriter

    /// Internal so tests can build an isolated Logger on a temp file; the app uses only `shared`.
    /// `nonisolated` so `shared` can be built off the main actor: nothing here touches isolated
    /// state, and the relay's handlers are `nonisolated` themselves.
    nonisolated init(logFileURL: URL) {
        self.logFileURL = logFileURL
        // The writer needs its failure callback at construction, to cover its startup trim, before
        // `self` can be captured; hence the relay, whose real handlers go in just below.
        let relay = WriteReportRelay()
        logWriter = LogFileWriter(
            url: logFileURL,
            onWriteFailure: { reason in relay.reportFailure(reason) },
            onWriteRecovered: { relay.reportRecovery() })
        relay.install(
            onFailure: { [weak self] reason in self?.noteDiskWriteFailure(reason) },
            onRecovery: { [weak self] in self?.noteDiskWriteRecovery() })
    }

    /// The in-memory-only notice that the disk log stopped accepting writes, once per failure run
    /// (`LogFileWriter.reportWriteFailure`). Not sent through `log()`, which would hand it back to
    /// the writer that just failed. Without it a full volume looks like a quiet session while
    /// `~/sync-cloud.log` silently stops growing.
    ///
    /// Per run, not per session: the notice can be evicted by the 1000-entry cap or cleared, so
    /// the writer re-arms on a successful write and on `clear()`. The `minimumLevel` gate doesn't
    /// apply: a raised threshold must not hide a line about the logging machinery itself.
    private nonisolated func noteDiskWriteFailure(_ reason: String) {
        let entry = LogEntry(
            level: .warning,
            message: "The log file \(logFileURL.lastPathComponent) could not be written: \(reason). "
                + "Activity Log entries continue in memory for this session, but the on-disk log has stopped growing.")
        // Same handoff every other entry uses (so it lands in order), minus the `logWriter.append`.
        _ = pendingEntries.enqueue(entry) { [weak self] in self?.flushPendingEntries() }
    }

    /// One line saying the disk log is accepting writes again, once per recovery, so a second
    /// failure doesn't read as a duplicate and the entries missing from the file are named. In
    /// memory only, like the failure notice: routing it through `logWriter.append` would make the
    /// recovery report depend on the write path it reports on.
    private nonisolated func noteDiskWriteRecovery() {
        let entry = LogEntry(
            level: .info,
            message: "The log file \(logFileURL.lastPathComponent) is being written again. "
                + "Entries recorded while it was unwritable are in this window only, not in the file.")
        _ = pendingEntries.enqueue(entry) { [weak self] in self?.flushPendingEntries() }
    }

    /// The `shared` logger's file: `~/sync-cloud.log`, except that tests must never fill or clear
    /// the real log. `SYNCCLOUD_LOG_FILE` overrides the path outright; under a test runner it is a
    /// per-process temp file (see `PerProcessTestFile`).
    nonisolated static func defaultLogFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SYNCCLOUD_LOG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if isRunningTests {
            return PerProcessTestFile.url(stem: PerProcessTestFile.logStem, extension: "log")
        }
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        return URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud.log")
    }

    // The message is an `@autoclosure` on all four, so a line the `minimumLevel` gate drops is
    // never built; some debug lines interpolate costly work, such as a whole-tree count. It does
    // forbid passing `Logger.shared.debug` as a function value.

    /// Records an informational trace event to memory and disk.
    /// - Parameter message: The string description to log.
    @discardableResult
    public nonisolated func info(_ message: @autoclosure () -> String) -> Task<Void, Never> {
        return log(level: .info, message: message())
    }

    /// Records a diagnostic debug event.
    /// - Parameter message: The string description to log.
    @discardableResult
    public nonisolated func debug(_ message: @autoclosure () -> String) -> Task<Void, Never> {
        return log(level: .debug, message: message())
    }

    /// Records a warning trace event to memory and disk.
    /// - Parameters:
    ///   - message: The string description of the warning.
    @discardableResult
    public nonisolated func warning(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line, function: String = #function) -> Task<Void, Never> {
        return log(level: .warning, message: "\(message()) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)")
    }

    /// Records an error trace event.
    /// - Parameter message: The string description of the failure.
    @discardableResult
    public nonisolated func error(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line, function: String = #function) -> Task<Void, Never> {
        return log(level: .error, message: "\(message()) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)")
    }

    /// FIFO handoff buffer between nonisolated log callers and the MainActor `entries` array.
    private let pendingEntries = PendingLogEntryQueue()

    /// Routes the entry to memory and disk. Both are ordered at the call site, not by task
    /// scheduling: the pending queue and the writer's serial queue each keep enqueue order, so lines
    /// land in call order. A task carrying each entry would let concurrent bursts reorder them.
    @discardableResult
    private nonisolated func log(level: LogLevel, message: @autoclosure () -> String) -> Task<Void, Never> {
        guard level.severity >= minimumLevel.severity else { return Task {} }
        let entry = LogEntry(level: level, message: message())
        // Awaiting the returned task guarantees the entry is in `entries`: it is the one flush
        // task covering the current burst (see `PendingLogEntryQueue`), which drains everything
        // enqueued before it runs.
        let flushTask = pendingEntries.enqueue(entry) { self.flushPendingEntries() }
        logWriter.append(entry.formattedString + "\n")
        return flushTask
    }

    @MainActor
    private func flushPendingEntries() {
        let batch = pendingEntries.drain()
        guard !batch.isEmpty else { return }
        entries.append(contentsOf: batch)

        // One trim and one republish per flush, not an O(count) shift per line at the cap.
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }
    }
    
    /// Posted after `clearLogs()` empties the session list and truncates the file, so every viewer
    /// holding parsed history can drop it, whichever button cleared.
    public static let didClearLogsNotification = Notification.Name("SyncCloudLoggerDidClearLogs")

    /// Empties memory and the file. Internal so no button can call it straight: both clear
    /// buttons (Activity Log, Settings ▸ Advanced) must go through `clearIfConfirmed`.
    func clearLogs() {
        // Drop entries still in the handoff queue too, or lines enqueued just before the clear
        // would flush into `entries` afterward and reappear.
        _ = pendingEntries.drain()
        entries.removeAll()
        logWriter.clear()
        NotificationCenter.default.post(name: Self.didClearLogsNotification, object: nil)
    }

    /// The control's one name, for its title, tooltip and VoiceOver label in both places.
    public nonisolated static let clearLogName = "Clear Log"
    /// What Clear Log asks, here so an Ask Claude card asks in the same words.
    public nonisolated static let clearPrompt = (
        messageText: "Clear the Activity Log?",
        informativeText: "Removes every entry from the Activity Log and empties the log file on disk, including earlier sessions. Your files aren’t affected, and this can’t be undone.")

    /// The clear gesture as one step: ask, and only then clear. Both buttons call this, so neither
    /// can forget to ask; `confirm` is a seam so the decision is testable without a modal.
    /// - Returns: Whether the log was cleared.
    @discardableResult
    public func clearIfConfirmed(_ confirm: @MainActor () -> Bool = Logger.defaultClearConfirmation) -> Bool {
        guard confirm() else { return false }
        clearLogs()
        return true
    }

    /// The same shape as Sync History's Clear: Cancel is the default button, and the destructive
    /// one takes no Return key. Clearing truncates the file on disk, which is the record of past
    /// sessions, and nothing brings it back.
    public static func defaultClearConfirmation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = clearPrompt.messageText
        alert.informativeText = clearPrompt.informativeText
        alert.addButton(withTitle: clearLogName)
        alert.addButton(withTitle: "Cancel")
        if let clearButton = alert.buttons.first {
            clearButton.hasDestructiveAction = true
            clearButton.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        return runModalCancellingOnEscape(alert) == .alertFirstButtonReturn
    }

    /// `NativeAlerts.runModalCancellingOnEscape`, which this package cannot import: Return on
    /// Cancel takes Escape from it, so a local monitor has Escape press the Return button instead.
    private static func runModalCancellingOnEscape(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let button = escapeAnswer(for: event, window: alert.window, buttons: alert.buttons)
            else { return event }
            button.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    /// `NativeAlerts.escapeAnswer`, for the same reason: the Return button, for a first Escape or
    /// ⌘. at the alert's window, unless a button already holds Escape.
    ///
    /// The window and buttons are taken apart because a test can't stage them together: ordering
    /// an alert's window in outside `runModal` clears its buttons' keys.
    static func escapeAnswer(for event: NSEvent, window: NSWindow, buttons: [NSButton]) -> NSButton? {
        guard event.type == .keyDown, !event.isARepeat, event.window === window else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Escape, or ⌘. — macOS's other cancel key, which an alert sends to its Escape button.
        let isEscape = event.keyCode == 53 && modifiers.isEmpty
        let isCommandPeriod = event.charactersIgnoringModifiers == "." && modifiers == .command
        guard isEscape || isCommandPeriod else { return nil }
        // An alert with a button still holding Escape answers it itself, and there the Return
        // button is the confirm: pressing it would turn Escape into yes.
        guard !buttons.contains(where: { $0.keyEquivalent == "\u{1b}" }) else { return nil }
        return buttons.first { $0.keyEquivalent == "\r" }
    }
    
    /// Blocks until every line logged before this call is on disk. For quitting: the writer runs at
    /// `.background` with no implicit flush, so an in-flight operation's last lines could be lost
    /// just when they matter. `applicationShouldTerminate` calls it before allowing the quit.
    public nonisolated func flushToDisk() {
        logWriter.flush()
    }

    /// The disk-writer barrier as a `@Sendable` value, so a detached read can wait behind queued
    /// writes off the main actor instead of blocking the UI in `flushToDisk()`. `Logger` isn't
    /// `Sendable`, so a detached closure can't capture it to call the method.
    public nonisolated func diskWriteBarrier() -> @Sendable () -> Void {
        let writer = logWriter
        return { writer.flush() }
    }

    /// Opens the log file in its default app (usually Console or TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}

/// Lock-guarded `LogLevel` cell readable/writable from any thread — `log()` runs on the
/// caller's thread, so the gate can't live in MainActor state.
private final class MinimumLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LogLevel = .debug

    func get() -> LogLevel {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: LogLevel) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Lock-guarded, late-bound handlers for the disk writer's failure and recovery reports. The
/// writer needs its callbacks at construction, since its startup trim can fail, before `Logger`
/// can capture `self`; the real handlers are installed as init finishes. A report arriving in that
/// gap is dropped, the right trade for a diagnostic. Both are installed together so a recovery
/// can't reach a relay that has only the failure handler.
private final class WriteReportRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var onFailure: (@Sendable (String) -> Void)?
    private var onRecovery: (@Sendable () -> Void)?

    func install(onFailure: @escaping @Sendable (String) -> Void,
                 onRecovery: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onFailure = onFailure
        self.onRecovery = onRecovery
        lock.unlock()
    }

    func reportFailure(_ reason: String) {
        lock.lock()
        let handler = onFailure
        lock.unlock()
        handler?(reason)
    }

    func reportRecovery() {
        lock.lock()
        let handler = onRecovery
        lock.unlock()
        handler?()
    }
}

/// Lock-guarded FIFO handing `LogEntry` values from nonisolated log callers to the MainActor
/// flush. Enqueue order is the order entries appear in the Activity Log.
///
/// A burst's enqueues share one MainActor flush task rather than a mostly no-op task per line.
/// The returned task still guarantees its entry is in `entries` when it completes: the marker
/// clears on the MainActor just before the drain, with no suspension between, so an entry too late
/// for a running drain sees no marker and schedules the next flush itself.
private final class PendingLogEntryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogEntry] = []
    /// The MainActor flush task covering everything currently in `pending`; nil once that
    /// task has started clearing/draining (guarded by `lock`).
    private var scheduledFlush: Task<Void, Never>?

    /// Appends the entry and returns the flush task that will make it visible, creating a
    /// task only when none is scheduled (the empty→non-empty transition of a burst).
    func enqueue(_ entry: LogEntry, flush: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        lock.lock()
        pending.append(entry)
        if let scheduledFlush {
            lock.unlock()
            return scheduledFlush
        }
        let task = Task { @MainActor [weak self] in
            self?.clearScheduledFlush()
            flush()
        }
        scheduledFlush = task
        lock.unlock()
        return task
    }

    private func clearScheduledFlush() {
        lock.lock()
        scheduledFlush = nil
        lock.unlock()
    }

    func drain() -> [LogEntry] {
        lock.lock()
        let batch = pending
        pending = []
        lock.unlock()
        return batch
    }
}

/// Appends log text to a file on a dedicated serial queue, keeping one `FileHandle` open across
/// writes instead of opening/seeking/closing per line. All handle access is confined to `queue`,
/// including the initial tail-trim and handle opening (appends enqueue behind them).
///
/// Internal so tests can drive the self-heal and truncation against a temp file; the app uses it
/// only through `Logger`.
final class LogFileWriter: @unchecked Sendable {
    /// Size cap for the log file, enforced at startup and re-checked periodically as the session
    /// writes. ~5 MB is tens of thousands of lines; an oversized file is trimmed to roughly half
    /// the cap so trims don't run back-to-back.
    private static let defaultMaxFileSize = 5 * 1024 * 1024

    private let url: URL
    private let queue = DispatchQueue(label: "com.synccloud.logger", qos: .background)
    private var handle: FileHandle?
    /// Inode of the file `handle` was opened on (confined to `queue`). Appends compare it with the
    /// path's current inode: another process's atomic rewrite keeps the path present but orphans
    /// the handle's inode, so existence alone can't detect a stale handle.
    private var handleFileIdentity: UInt64?
    private let maxFileSize: Int

    /// Bytes appended since the last mid-session size check (confined to `queue`). The check runs
    /// each time this crosses `trimCheckInterval`, not per line, so a long session stays near the
    /// cap without a stat on every write.
    private var bytesSinceTrimCheck = 0
    private let trimCheckInterval: Int

    /// Called on `queue` with the description of a disk-write failure, once per failure run. A
    /// full or unmounted volume fails every later line too, so a report per failure would be one
    /// per line; one per run answers "did the on-disk log stop growing?" See
    /// `Logger.noteDiskWriteFailure`.
    ///
    /// The latch, `didReportWriteFailure`, re-arms (`noteWriteSucceeded`, `clear`): the notice
    /// lives only in memory, so once evicted or cleared, a one-shot latch could never report again.
    private let onWriteFailure: (@Sendable (String) -> Void)?

    /// Called on `queue` the first time a write succeeds after a reported failure, so a second
    /// failure notice doesn't read like a duplicate of the first.
    private let onWriteRecovered: (@Sendable () -> Void)?

    /// Whether a failure has been reported and not yet superseded by a success or a `clear()`
    /// (confined to `queue`, like the handle itself).
    private var didReportWriteFailure = false

    init(url: URL,
         maxFileSize: Int = LogFileWriter.defaultMaxFileSize,
         onWriteFailure: (@Sendable (String) -> Void)? = nil,
         onWriteRecovered: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.maxFileSize = maxFileSize
        self.onWriteFailure = onWriteFailure
        self.onWriteRecovered = onWriteRecovered
        trimCheckInterval = min(1024 * 1024, max(1, maxFileSize / 2))
        queue.async { [self] in
            withTrimLock { trimTailIfOversized(maxFileSize: maxFileSize) }
            openHandle()
        }
    }

    /// Runs `body` holding an exclusive `flock` on `<log>.lock`. The app and the `synccloud` CLI
    /// share `~/sync-cloud.log`, and a trim rewrites the whole file from its tail, so two
    /// concurrent trims could clobber each other. The size is stat'ed inside `body`, so a trim that
    /// lost the race finds nothing left to do.
    ///
    /// Accepted: appends aren't locked, so the other process can lose one in-flight line to a
    /// trim's rename before its next append reopens. Locking every append would put a
    /// cross-process syscall on the hot path. If the lock file can't be opened, the trim runs
    /// unguarded rather than letting the log grow unbounded. Runs on `queue`.
    private func withTrimLock(_ body: () -> Void) {
        let fd = open(url.path + ".lock", O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            body()
            return
        }
        defer { close(fd) }  // close releases the flock too
        _ = flock(fd, LOCK_EX)
        body()
        _ = flock(fd, LOCK_UN)
    }

    /// Inode of the item currently at `url`; nil when the path does not exist. One
    /// `attributesOfItem` stat answers both existence and identity. Runs on `queue`.
    private func currentFileIdentity() -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// (Re)opens the write handle positioned at end-of-file, creating the file if missing, and
    /// records the opened file's identity for the staleness check in `append`. Runs on `queue`.
    private func openHandle() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        // O_APPEND, so the kernel puts every write at the true end of file atomically. Otherwise
        // the CLI, sharing the file, could write between our seek and write, and one line would
        // overwrite the other.
        let fd = open(url.path, O_WRONLY | O_APPEND)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        handleFileIdentity = handle == nil ? nil : currentFileIdentity()
    }

    /// Tail-trims the file when it exceeds `maxFileSize`, keeping the newest half of the cap
    /// aligned to a line boundary, so `~/sync-cloud.log` cannot grow unbounded across runs.
    /// Runs on `queue` before the write handle opens.
    private func trimTailIfOversized(maxFileSize: Int) {
        guard maxFileSize > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxFileSize,
              let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }

        let keepBytes = maxFileSize / 2
        guard (try? readHandle.seek(toOffset: UInt64(size - keepBytes))) != nil,
              var tail = try? readHandle.readToEnd() else { return }
        // Drop the partial first line so the trimmed file still starts at a line boundary.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        // A failed trim leaves the file oversized but intact. It fails for the same reasons an
        // append does (no space, volume gone), so it feeds the same report.
        do {
            try tail.write(to: url, options: .atomic)
        } catch {
            reportWriteFailure(error)
        }
    }

    /// Fires `onWriteFailure` for the first failure of a run only. Runs on `queue`.
    private func reportWriteFailure(_ error: Error) {
        guard !didReportWriteFailure else { return }
        didReportWriteFailure = true
        onWriteFailure?(error.localizedDescription)
    }

    /// Ends the current failure run: re-arms the report and announces the recovery, once. Runs on
    /// `queue`, from the append path only: a trim writes a new file and can succeed when appends
    /// can't, and "being written again" must mean the lines are landing.
    private func noteWriteSucceeded() {
        guard didReportWriteFailure else { return }
        didReportWriteFailure = false
        onWriteRecovered?()
    }

    /// Re-arms the failure report without announcing a recovery, for `clear()`: its truncate
    /// succeeding doesn't prove appends will land, and the notice a recovery would pair with was
    /// just cleared. Runs on `queue`.
    private func rearmWriteFailureReport() {
        didReportWriteFailure = false
    }

    /// Reopens the write handle when the path's inode no longer matches it: never opened, removed,
    /// or replaced by an atomic rewrite such as the CLI's trim, which keeps the path but swaps the
    /// inode. One stat per call. Every handle operation goes through this one helper, or it would
    /// act on an orphaned inode (a clear would leave every line in the file). Runs on `queue`.
    private func reopenHandleIfStale() {
        guard handle == nil || currentFileIdentity() != handleFileIdentity else { return }
        try? handle?.close()
        handle = nil
        openHandle()
    }

    func append(_ text: String) {
        queue.async { [weak self] in
            guard let self, let data = text.data(using: .utf8) else { return }
            // Otherwise an externally replaced log would swallow every line into an orphaned inode.
            self.reopenHandleIfStale()
            // Both branches feed the failure report, since a line that never reaches disk is
            // otherwise invisible. Still best-effort and non-throwing.
            do {
                if let handle = self.handle {
                    _ = try? handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    // Fallback while the handle can't be opened. Append by hand: a bare `.atomic`
                    // write would replace the whole log with this one line. It rewrites the file
                    // per line, but only until the next append reopens the handle.
                    let existing = (try? Data(contentsOf: self.url)) ?? Data()
                    try (existing + data).write(to: self.url, options: .atomic)
                }
                // The line reached disk, so any failure run is over.
                self.noteWriteSucceeded()
            } catch {
                self.reportWriteFailure(error)
            }
            self.bytesSinceTrimCheck += data.count
            if self.bytesSinceTrimCheck >= self.trimCheckInterval {
                self.bytesSinceTrimCheck = 0
                self.trimMidSessionIfOversized()
            }
        }
    }

    /// The mid-session trim. It writes a new inode, so the handle is closed first and reopened
    /// after, or later appends would vanish into the old one. The size is checked under the lock,
    /// since the other process may have just trimmed and a second cut would lose fresh lines.
    /// Runs on `queue`.
    private func trimMidSessionIfOversized() {
        withTrimLock {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size > maxFileSize else { return }
            try? handle?.close()
            handle = nil
            trimTailIfOversized(maxFileSize: maxFileSize)
            openHandle()
        }
    }

    /// Blocks until every append and clear enqueued before it has finished. Behind
    /// `Logger.flushToDisk()` at quit (app and CLI); tests use it before reading the file.
    func flush() {
        queue.sync {}
    }

    /// Truncates the log file to empty, keeping the open handle valid. Reopens first, as `append`
    /// does, or after the CLI's atomic trim the clear would empty an orphaned inode and leave the
    /// file full. A deleted log is therefore recreated empty, which is harmless: the history loader
    /// reads no file and an empty file alike, and Settings then shows "Zero bytes".
    ///
    /// Clearing also re-arms the failure report, so a failure after it is news, not a repeat.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reopenHandleIfStale()
            // Re-armed before the writes, so a clear that can't write reports itself as the first
            // failure of the new run instead of being swallowed by the old latch.
            self.rearmWriteFailureReport()
            // Both branches feed the same failure report `append` uses.
            do {
                if let handle = self.handle {
                    try handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                } else {
                    try "".write(to: self.url, atomically: true, encoding: .utf8)
                }
            } catch {
                self.reportWriteFailure(error)
            }
        }
    }
}
