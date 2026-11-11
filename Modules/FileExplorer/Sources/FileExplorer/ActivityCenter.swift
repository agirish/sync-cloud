import AppKit
import Combine
import Design
import Sync

/// One message in Activity's Recent list — a result as the window or Edit said it, kept in full.
public struct ActivityMessage: Identifiable, Equatable {
    public let id: UUID
    /// When it was said — the newest repeat's time, once repeats fold.
    public var date: Date
    public var message: String
    public var detail: String?
    public var severity: OperationBanner.Severity
    public var followUps: [OperationBanner.FollowUp]
    /// "×4": the same sentence said again in a row, folded into this row.
    public var repeats: Int
    /// The undo step this message's operation registered, when it offered Undo. The row's Undo is
    /// live only while that step is still the newest.
    public var undoStep: Int?
    /// The Sync History run it reported, from the operation that recorded it
    /// (`OperationBanner.runId`): Events draws it as that run's sentence.
    public var runId: UUID?
    /// The minutes its run wrote to the log, for Show in Log.
    public var span: ClosedRange<Date>
    /// Whose doors its follow-ups open — the window's panes, or Edit's own PDF.
    public var source: Source
    /// The run was stopped by the reader: drawn as a grey ending saying what was kept, not a problem.
    public var isStopped = false
    /// The repeats folded into this row; a notification names the one it reported.
    public var foldedIDs: [UUID] = []
    /// A refusal (`OperationBanner.isRefusal`): shown this session, never kept past it.
    public var isRefusal = false
    /// A note about something still under way (`OperationBanner.isInProgress`): shown this
    /// session, never kept past it, and no problem for the dot.
    public var isInProgress = false
    /// Read back from an earlier session's file: never folded into by this session's messages,
    /// whose Undo, Download and minutes belong to now.
    public var isFromEarlierSession = false

    public enum Source: String, Codable, Equatable {
        case window
        case edit
    }

    public init(id: UUID = UUID(), date: Date = Date(), message: String, detail: String? = nil,
                severity: OperationBanner.Severity, followUps: [OperationBanner.FollowUp] = [],
                repeats: Int = 1, undoStep: Int? = nil, runId: UUID? = nil,
                span: ClosedRange<Date>? = nil, source: Source = .window) {
        self.id = id
        self.date = date
        self.message = message
        self.detail = detail
        self.severity = severity
        self.followUps = followUps
        self.repeats = repeats
        self.undoStep = undoStep
        self.runId = runId
        self.span = span ?? date.addingTimeInterval(-60)...date.addingTimeInterval(5)
        self.source = source
    }

    /// Whether a sentence reports a run the reader stopped, in the app's own words for it:
    /// "Stopped. Saved 2 of 6 as PDF.", "Canceled. Saved 1 rotated copy", "Verify All canceled".
    public static func saysStopped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["stopped", "canceled"].contains { lower.hasPrefix($0) }
            || [" canceled", " stopped"].contains { lower.hasSuffix($0) || lower.hasSuffix($0 + ".") }
    }

    /// A stop is drawn grey unless it also failed: "Canceled. Nothing was saved · 1 failed" is a
    /// problem the reader didn't cause, and keeps its red and its dot.
    static func isQuietStop(stopped: Bool, message: String, severity: OperationBanner.Severity) -> Bool {
        guard stopped, severity != .error else { return false }
        let lower = message.lowercased()
        return !["failed", "couldn’t"].contains { lower.contains($0) }
    }

    /// The same words and the same weight — what folds a repeat into the row before it. Never a
    /// message that reports a run: each run is a row of its own in Events, led by its own message.
    func saysTheSame(as other: ActivityMessage) -> Bool {
        message == other.message && detail == other.detail && severity == other.severity
            && followUps == other.followUps && source == other.source && undoStep == nil && other.undoStep == nil
            && runId == nil && other.runId == nil && isRefusal == other.isRefusal
            && isInProgress == other.isInProgress
            && !isFromEarlierSession && !other.isFromEarlierSession
    }
}

/// What a row's buttons need from the app: the main window's doors.
public struct ActivityDoors {
    public var openInEdit: (String) -> Void
    public var reveal: ([String]) -> Void
    public var download: (String) -> Void
    public var showInLog: (ClosedRange<Date>) -> Void
    /// A long scan's Show: opens its card.
    public var showScan: (ActivityScan) -> Void

    public init(openInEdit: @escaping (String) -> Void = { _ in }, reveal: @escaping ([String]) -> Void = { _ in },
                download: @escaping (String) -> Void = { _ in },
                showInLog: @escaping (ClosedRange<Date>) -> Void = { _ in },
                showScan: @escaping (ActivityScan) -> Void = { _ in }) {
        self.openInEdit = openInEdit
        self.reveal = reveal
        self.download = download
        self.showInLog = showInLog
        self.showScan = showScan
    }
}

/// Activity's one owner for the whole app: the pane-launched PDF runs, Save as PDF, and Recent
/// (every message, newest first: this session's, and the kept ones from earlier sessions). The capsule's popover and the Activity window read
/// the same instance, so they list the same runs and messages.
///
/// Recent is a copy, not a queue: the window still shows one message at a time, but each is written
/// here the moment it is published. Nothing here speaks; VoiceOver heard the message where it showed.
@MainActor
public final class ActivityCenter: ObservableObject {
    public static let shared = ActivityCenter()
    /// The Activity window's scene.
    public static let windowID = "activity"

    /// Recent keeps as many as the store does: every message but a refusal is kept across quits.
    public static let keep = ActivityMessageStore.maxMessages

    /// The PDF tools run from a pane's row menu.
    public let panePDFTools = PanePDFTools()
    /// Save as PDF from a pane's row menu or File ▸.
    public let paneSaveAsPDF = PaneSaveAsPDF()

    @Published public private(set) var recent: [ActivityMessage] = [] {
        didSet { recentVersion &+= 1 }
    }
    /// Bumped with every change to `recent`, in place ones included: what Events' cached timeline is
    /// keyed by, so a redraw that changed nothing rebuilds nothing.
    public private(set) var recentVersion = 0
    /// A problem arrived that nobody has seen: the toolbar's Activity button wears a dot until
    /// Activity is opened.
    @Published public private(set) var hasUnseenProblem = false
    /// A problem the capsule is still showing, whose dot waits until the message goes into Activity,
    /// so the dot appears as the ring lands on the button. Set only when no dot was already showing,
    /// so a hold never hides an older problem's.
    @Published public private(set) var dotHeldFor: UUID?
    /// Whether the Activity button wears its dot now.
    public var showsDot: Bool { hasUnseenProblem && dotHeldFor == nil }
    /// The Recent row a capsule message arriving flashes once, and the count its flash animates on.
    @Published public private(set) var flashedRow: UUID?
    @Published public private(set) var flashes = 0
    /// The Activity window's tab: the last one used, which the button and ⌘L reopen.
    @Published public var tab: ActivityTab = .events
    /// Show in Log's minutes: set by a message's row, read by the Log tab.
    @Published public var logSpan: ClosedRange<Date>?
    /// One-way sync's History… asked for its entries alone, and Events hasn't shown them yet: kept
    /// until Events appears, which may be after the window opens.
    @Published public var wantsOneWaySyncHistory = false
    /// A row Events should bring into view, once: a notification's click, Show in Events, a
    /// problem waiting. Events takes it (setting nil) when it scrolls there, so the same row can be
    /// asked for again, and coming back to the tab later doesn't jump.
    @Published public var pointRequest: UUID?
    /// The popover under the capsule is open, so the capsule stays for it.
    @Published public var popoverIsOpen = false
    /// The Recent row a notification's click picked out, drawn marked until another is.
    @Published public var highlighted: UUID?
    /// Bumped to ask the main window to open the Activity window, since a notification's click
    /// arrives where no view can open one.
    @Published public private(set) var windowRequests = 0
    /// The main window's undo steps as ids, newest last: pushed as a step opens, moved to
    /// `redoSteps` by an undo and back by a redo, so a row can tell whether its step is the newest
    /// again after a newer one was undone.
    @Published public private(set) var undoSteps: [Int] = []
    private var redoSteps: [Int] = []
    private var nextStep = 0

    /// The main window's doors, set by it.
    public var doors = ActivityDoors()
    /// Where Recent is kept across quits; nil until ``attachMessages(_:now:)``, as in tests.
    private(set) var messageStore: ActivityMessageStore?
    /// The file operations' undo stack: the main window's.
    public private(set) weak var undoManager: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []

    public init() {}

    // MARK: Recent

    /// Writes a message into Recent: folded into the newest row when it says the same again, then
    /// trimmed to the newest `keep`. `seen` is whether it showed where the reader was looking; a
    /// problem that didn't leaves the dot on the Activity button. `dotWaits`: the message is the
    /// capsule's, so its dot waits for ``releaseDot()``.
    public func record(_ message: ActivityMessage, seen: Bool, dotWaits: Bool = false) {
        // The same message published again with its words amended (a delete's "Includes 3 items
        // the filter is hiding"): one row, updated, not a second row with the same id.
        if let index = recent.firstIndex(where: { $0.id == message.id }) {
            var row = message
            row.repeats = recent[index].repeats
            row.foldedIDs = recent[index].foldedIDs
            recent[index] = row
            messageStore?.save(row)
            return
        }
        if let newest = recent.first, newest.saysTheSame(as: message) {
            recent[0].repeats += 1
            recent[0].foldedIDs.append(message.id)
            recent[0].date = message.date
            // Show in Log covers every repeat, not only the first.
            recent[0].span = min(newest.span.lowerBound, message.span.lowerBound)
                ... max(newest.span.upperBound, message.span.upperBound)
        } else {
            recent.insert(message, at: 0)
            if recent.count > Self.keep { recent.removeLast(recent.count - Self.keep) }
        }
        // The row as it now stands, folded or new; the store keeps all but a refusal or a note.
        messageStore?.save(recent[0])
        // A stop the reader asked for is not a problem they missed, nor is a note of what is
        // still under way.
        if message.severity != .success, !message.isStopped, !message.isInProgress, !seen {
            if dotWaits, !hasUnseenProblem { dotHeldFor = message.id }
            hasUnseenProblem = true
        }
    }

    /// The held problem's message went into Activity (landed, replaced or cleared); none of those
    /// may lose its dot.
    public func releaseDot() {
        if dotHeldFor != nil { dotHeldFor = nil }
    }

    /// Releases the hold only if it is `messageID`'s: one message's landing or leaving must not
    /// show the dot of another still in the capsule.
    public func releaseDot(heldFor messageID: UUID) {
        if dotHeldFor == messageID { dotHeldFor = nil }
    }

    /// Flashes `messageID`'s row once; a repeat folded into an earlier row flashes that row.
    public func flashRow(for messageID: UUID) {
        flashedRow = recent.first { $0.foldedIDs.contains(messageID) }?.id ?? messageID
        flashes &+= 1
    }

    /// The window's message, as it was published, with the run it reports when the operation
    /// that recorded one put its id on it. `finishedRun` is the last long run's minutes, when it
    /// ended just now.
    public func record(_ banner: OperationBanner, finishedRun: (started: Date, ended: Date, cancelled: Bool)?,
                       seen: Bool, dotWaits: Bool = false, now: Date = Date()) {
        var start = now.addingTimeInterval(-60)
        var stoppedRun = false
        if let finishedRun, now.timeIntervalSince(finishedRun.ended) < 10 {
            start = min(start, finishedRun.started)
            // Only the run's own ending is its stop: the first message after its progress cleared,
            // in that turn. A delete or a failure a moment later is not.
            if now.timeIntervalSince(finishedRun.ended) < 2, finishedRun.ended != stopClaimedBy {
                stopClaimedBy = finishedRun.ended
                stoppedRun = finishedRun.cancelled
            }
        }
        var message = ActivityMessage(id: banner.id, date: now, message: banner.message, detail: banner.detail,
                                      severity: banner.severity, followUps: banner.followUps,
                                      undoStep: banner.isUndoable ? undoSteps.last : nil, runId: banner.runId,
                                      span: start...now.addingTimeInterval(5))
        message.isStopped = ActivityMessage.isQuietStop(stopped: stoppedRun || ActivityMessage.saysStopped(banner.message),
                                                        message: banner.message, severity: banner.severity)
        message.isRefusal = banner.isRefusal
        message.isInProgress = banner.isInProgress
        record(message, seen: seen, dotWaits: dotWaits)
    }

    /// The ended run whose ending a message already reported, named by when it ended.
    private var stopClaimedBy: Date?

    /// Edit's own PDF tool and Fill & Sign results, which live on Edit's model rather than in the
    /// window's message. Edit's disk-change and read-only notices are questions, not messages, and
    /// never come here.
    public func record(_ banner: EditorPDFToolBanner, seen: Bool) {
        let result = PaneToolResult(banner, host: PanePDFToolHost())
        var message = ActivityMessage(message: result.banner.message, detail: result.banner.detail,
                                      severity: result.banner.severity, followUps: result.banner.followUps,
                                      source: .edit)
        message.isStopped = ActivityMessage.isQuietStop(stopped: ActivityMessage.saysStopped(result.banner.message),
                                                        message: result.banner.message, severity: result.banner.severity)
        message.isRefusal = result.banner.isRefusal
        record(message, seen: seen)
    }

    /// Clears every message, the kept ones from earlier sessions too. The runs keep their records.
    public func clear() {
        recent = []
        hasUnseenProblem = false
        dotHeldFor = nil
        messageStore?.clearAll()
    }

    /// Asks before Clear: it removes what earlier sessions kept too, which nothing else has.
    /// Cancel is the default and the destructive button takes no Return, as History's clears do.
    public static func confirmClearMessages() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear every message?"
        alert.informativeText = "Removes the messages Activity kept, from this session and earlier ones. Runs keep their records in Events, and the log keeps its lines."
        alert.addButton(withTitle: "Clear Messages")
        alert.addButton(withTitle: "Cancel")
        if let clear = alert.buttons.first {
            clear.hasDestructiveAction = true
            clear.keyEquivalent = ""
        }
        alert.buttons.last?.keyEquivalent = "\r"
        return NativeAlerts.runModalCancellingOnEscape(alert) == .alertFirstButtonReturn
    }

    // MARK: Kept across quits

    /// Reads the kept messages in under any this session recorded before it: at launch. They light
    /// no dot, whatever they say: they were seen, or not, in the session that showed them.
    public func attachMessages(_ store: ActivityMessageStore, now: Date = Date()) {
        messageStore = store
        let mine = Set(recent.map(\.id))
        let kept = store.load(now: now)
        // What this launch said before the store was attached is kept too.
        for message in recent { store.save(message) }
        recent += kept.filter { !mine.contains($0.id) }
        recent.sort { $0.date > $1.date }
        if recent.count > Self.keep { recent.removeLast(recent.count - Self.keep) }
    }

    /// Sync History was cleared: the messages that reported its runs go with them, or Events would
    /// list each as a row of its own with nothing behind it.
    public func forgetRunMessages() {
        recent.removeAll { $0.runId != nil }
        messageStore?.forgetRunMessages()
    }

    /// Waits for the kept messages to reach the disk: at quit.
    public func flushMessages() {
        messageStore?.flush()
    }

    /// Activity was opened: whatever problem was waiting has been seen.
    public func markSeen() {
        if hasUnseenProblem { hasUnseenProblem = false }
        releaseDot()
    }

    /// The Activity window on Events, with `id`'s row picked out: the message's own row, or the
    /// run's row it is the sentence of.
    public func openWindow(highlighting id: UUID?) {
        // A repeat folded into an earlier row is that row.
        highlighted = id.map { id in recent.first { $0.foldedIDs.contains(id) }?.id ?? id }
        pointRequest = highlighted
        tab = .events
        markSeen()
        windowRequests += 1
    }

    /// The tab the button and ⌘L open: the last one used, or Events while a problem waits.
    public func tabForOpening() -> ActivityTab {
        if hasUnseenProblem {
            tab = .events
            // Pointed at, so a filter left on can't hide it.
            if let problem = recent.first(where: { $0.severity != .success && !$0.isStopped && !$0.isRefusal && !$0.isInProgress }) {
                highlighted = problem.id
                pointRequest = problem.id
            }
        }
        return tab
    }

    /// Events showing one-way sync's entries alone: one-way sync's History…. The caller opens the
    /// window.
    public func showOneWaySyncHistory() {
        tab = .events
        wantsOneWaySyncHistory = true
    }

    // MARK: One-way sync (RD67, DC)

    /// The one-way sync rows above Events' timeline, saved so they survive a quit: *Needs you* until answered or the
    /// cause clears, information until dismissed. Empty until ``attachOneWaySync(_:now:)``.
    @Published public private(set) var oneWaySync = OneWaySyncNoticeBoard()
    /// The row a one-way sync notification's click picked out.
    @Published public var highlightedNotice: String?
    /// Posts a notification that is due — set by the app, which checks the opt-in.
    public var postOneWaySyncNotice: (OneWaySyncNoticeDelivery) -> Void = { _ in }
    private(set) var oneWaySyncStore: OneWaySyncNoticeStore?

    /// Reads the saved rows and sends whatever came due while SyncCloud was closed. Rows raised
    /// before this are kept, on top of the saved ones.
    public func attachOneWaySync(_ store: OneWaySyncNoticeStore, now: Date = Date()) {
        oneWaySyncStore = store
        // Unreadable (a newer build's, or damaged): moved aside by the store, and each pass raises
        // again what still waits.
        var board = store.load(now: now).value ?? OneWaySyncNoticeBoard()
        for row in oneWaySync.rows { board.raise(row) }
        oneWaySync = board
        settleOneWaySync(now: now)
    }

    /// Raises rows, or updates the rows their causes already have: no second notification.
    public func raiseOneWaySync(_ notices: [OneWaySyncNotice], now: Date = Date()) {
        var board = oneWaySync
        for notice in notices { board.raise(notice) }
        oneWaySync = board
        settleOneWaySync(now: now)
    }

    /// A row was answered, or its cause cleared.
    public func clearOneWaySync(_ ids: [String], now: Date = Date()) {
        var board = oneWaySync
        for id in ids { board.clear(id) }
        oneWaySync = board
        settleOneWaySync(now: now)
    }

    /// Dismisses an information row; a *Needs you* row stays.
    public func dismissOneWaySync(_ id: String) {
        var board = oneWaySync
        guard board.dismiss(id) else { return }
        oneWaySync = board
        oneWaySyncStore?.save(board)
    }

    /// Waits for the rows' saves to reach the disk: at quit.
    public func flushOneWaySync() {
        oneWaySyncStore?.flush()
    }

    /// Sends the reminders due now: the app asks hourly and on wake.
    public func remindOneWaySync(now: Date = Date()) {
        settleOneWaySync(now: now)
    }

    /// The Activity window on Events, with a one-way sync row picked out.
    public func openWindow(highlightingNotice id: String) {
        highlightedNotice = oneWaySync.shownRow(for: id) ?? id
        tab = .events
        markSeen()
        windowRequests += 1
    }

    /// Marks what is due as sent, saves, then posts. With something to post it waits for the save,
    /// so a crash between the two loses a notification rather than repeating one.
    private func settleOneWaySync(now: Date) {
        var board = oneWaySync
        let due = board.deliveries(now: now)
        if board != oneWaySync { oneWaySync = board }
        if due.isEmpty {
            oneWaySyncStore?.save(board)
        } else {
            oneWaySyncStore?.saveNow(board)
        }
        due.forEach(postOneWaySyncNotice)
    }

    // MARK: Undo (TE223, R12)

    /// Watches the main window's undo stack. Called by the window whenever its manager changes.
    public func watchUndo(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
        undoObservers = []
        undoManager = manager
        // Another stack: no row's step is on it.
        undoSteps = []
        redoSteps = []
        guard let manager else { return }
        let names: [Notification.Name] = [.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange]
        for name in names {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: manager,
                                                                        queue: .main) { [weak self, weak manager] _ in
                MainActor.assumeIsolated {
                    self?.undoStackMoved(name, groupingLevel: manager?.groupingLevel ?? 0)
                }
            })
        }
    }

    func undoStackMoved(_ name: Notification.Name, groupingLevel: Int) {
        switch name {
        case .NSUndoManagerDidOpenUndoGroup:
            // An inner group is part of the step already counted; a new step ends what redo had.
            guard groupingLevel <= 1 else { return }
            nextStep += 1
            undoSteps.append(nextStep)
            redoSteps = []
        case .NSUndoManagerDidUndoChange:
            if let step = undoSteps.popLast() { redoSteps.append(step) }
        case .NSUndoManagerDidRedoChange:
            if let step = redoSteps.popLast() { undoSteps.append(step) }
        default:
            break
        }
    }

    /// Why a row's Undo cannot act, or `nil` when it can: its step must still be the newest on the
    /// stack, as ⌘Z would take it. The way back past a newer step is ⌘Z, one step at a time.
    public func undoRefusal(for message: ActivityMessage) -> String? {
        guard let step = message.undoStep else { return "" }
        if redoSteps.contains(step) { return "Already undone — ⇧⌘Z in the main window puts it back." }
        guard let undoManager, undoManager.canUndo, undoSteps.contains(step) else {
            return "Nothing to undo — the undo history resets when SyncCloud restarts."
        }
        guard step == undoSteps.last else {
            let newer = undoManager.undoActionName
            return newer.isEmpty ? "Undo the newer steps first, with ⌘Z in the main window."
                                 : "Undo the newer “\(newer)” first."
        }
        return nil
    }

    /// Reverses the row's step on the main window's stack — the step ⌘Z there would take.
    public func undo(_ message: ActivityMessage) {
        guard undoRefusal(for: message) == nil else { return }
        undoManager?.undo()
    }
}

/// The Activity window's two tabs: Events, what runs and needs you above everything SyncCloud did,
/// and Log, the lines it wrote.
public enum ActivityTab: String, CaseIterable, Identifiable, Sendable {
    case events, log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .events: return "Events"
        case .log: return "Log"
        }
    }
}
