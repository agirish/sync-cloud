import AppKit
import Combine
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
    /// "×4": the same sentence said again in a row, folded into this row (R14).
    public var repeats: Int
    /// The undo step this message's operation registered, when it offered Undo — what makes its
    /// row's Undo live only while that step is still the newest (TE223).
    public var undoStep: Int?
    /// The Sync History run it reported, for Show in History (R13).
    public var runId: UUID?
    /// The minutes its run wrote to the log, for Show in Log (R13).
    public var span: ClosedRange<Date>
    /// Whose doors its follow-ups open — the window's panes, or Edit's own PDF.
    public var source: Source
    /// The run was stopped by the reader — a grey ending saying what was kept, not a problem
    /// (TE221).
    public var isStopped = false
    /// The repeats folded into this row (R14) — a notification names the one it reported.
    public var foldedIDs: [UUID] = []

    public enum Source: Equatable {
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

    /// **Whether a sentence reports a run the reader stopped** — the app's own words for it:
    /// "Stopped. Saved 2 of 6 as PDF.", "Canceled. Saved 1 rotated copy", "Verify All canceled".
    public static func saysStopped(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["stopped", "canceled"].contains { lower.hasPrefix($0) }
            || [" canceled", " stopped"].contains { lower.hasSuffix($0) || lower.hasSuffix($0 + ".") }
    }

    /// **A stop drawn grey** — unless it also failed: "Canceled. Nothing was saved · 1 failed" is a
    /// problem the reader stopping it did not cause, and keeps its red and its dot.
    static func isQuietStop(stopped: Bool, message: String, severity: OperationBanner.Severity) -> Bool {
        guard stopped, severity != .error else { return false }
        let lower = message.lowercased()
        return !["failed", "couldn’t"].contains { lower.contains($0) }
    }

    /// The same words and the same weight — what folds a repeat into the row before it.
    func saysTheSame(as other: ActivityMessage) -> Bool {
        message == other.message && detail == other.detail && severity == other.severity
            && followUps == other.followUps && source == other.source && undoStep == nil && other.undoStep == nil
    }
}

/// What a row's buttons need from the app: the main window's doors.
public struct ActivityDoors {
    public var openInEdit: (String) -> Void
    public var reveal: ([String]) -> Void
    public var download: (String) -> Void
    public var showInHistory: (UUID) -> Void
    public var showInLog: (ClosedRange<Date>) -> Void
    /// A long scan's Show — its card (TE228).
    public var showScan: (ActivityScan) -> Void

    public init(openInEdit: @escaping (String) -> Void = { _ in }, reveal: @escaping ([String]) -> Void = { _ in },
                download: @escaping (String) -> Void = { _ in }, showInHistory: @escaping (UUID) -> Void = { _ in },
                showInLog: @escaping (ClosedRange<Date>) -> Void = { _ in },
                showScan: @escaping (ActivityScan) -> Void = { _ in }) {
        self.openInEdit = openInEdit
        self.reveal = reveal
        self.download = download
        self.showInHistory = showInHistory
        self.showInLog = showInLog
        self.showScan = showScan
    }
}

/// **Activity's one owner, for the whole app** (Run Room, R11): the pane-launched PDF runs and
/// Save as PDF, which the main window's view used to hold, and Recent — every message this session,
/// newest first (TE222, decisions CL and CM). The capsule's popover and the Activity window read the
/// same instance, so they list the same runs and the same messages.
///
/// Recent is a copy, not a queue (R9): the window still shows one message at a time and a second
/// replaces the first on screen, but each is written here the moment it is published. Nothing here
/// speaks — VoiceOver heard the message where it showed (R19).
@MainActor
public final class ActivityCenter: ObservableObject {
    public static let shared = ActivityCenter()
    /// The Activity window's scene.
    public static let windowID = "activity"

    /// Recent keeps the newest fifty, until SyncCloud quits (CM).
    public static let keep = 50

    /// The PDF tools run from a pane's row menu.
    public let panePDFTools = PanePDFTools()
    /// Save as PDF from a pane's row menu or File ▸.
    public let paneSaveAsPDF = PaneSaveAsPDF()

    @Published public private(set) var recent: [ActivityMessage] = []
    /// A problem arrived that nobody has seen — the toolbar's Activity button wears a dot until
    /// Activity is opened (TE224, decision CS).
    @Published public private(set) var hasUnseenProblem = false
    /// **A problem the capsule is still showing**, whose dot waits until the message goes into
    /// Activity — the ring lands on the button and the dot appears with it. Set only when no dot was
    /// already showing, so a hold never hides an older problem's.
    @Published public private(set) var dotHeldFor: UUID?
    /// Whether the Activity button wears its dot now.
    public var showsDot: Bool { hasUnseenProblem && dotHeldFor == nil }
    /// The Recent row a capsule message arriving flashes once, and the count its flash animates on.
    @Published public private(set) var flashedRow: UUID?
    @Published public private(set) var flashes = 0
    /// The Activity window's tab — the last one used, which the button and ⌘L reopen (CT).
    @Published public var tab: ActivityTab = .now
    /// Show in History's run, and Show in Log's minutes: set by a Recent row, read by the tab.
    @Published public var historyRun: UUID?
    @Published public var logSpan: ClosedRange<Date>?
    /// The popover under the capsule is open — the capsule stays for it (TE231).
    @Published public var popoverIsOpen = false
    /// The Recent row a notification's click picked out (TE227), drawn marked until another is.
    @Published public var highlighted: UUID?
    /// Bumped to ask the main window to open the Activity window — a notification's click arrives
    /// where no view can open one.
    @Published public private(set) var windowRequests = 0
    /// The main window's undo steps as ids, newest last — pushed as a step opens, moved to
    /// `redoSteps` by an undo and back by a redo — so a row can tell whether its step is the newest
    /// again after a newer one was undone (TE223).
    @Published public private(set) var undoSteps: [Int] = []
    private var redoSteps: [Int] = []
    private var nextStep = 0

    /// The main window's doors, set by it.
    public var doors = ActivityDoors()
    /// The file operations' undo stack — the main window's (R12).
    public private(set) weak var undoManager: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []

    public init() {}

    // MARK: Recent

    /// Writes a message into Recent: folded into the newest row when it says the same again, then
    /// trimmed to the newest fifty. `seen` is whether it showed where the reader was looking — a
    /// problem that did not leaves the dot on the Activity button. `dotWaits`: the message is the
    /// capsule's, so its dot waits for ``releaseDot()``.
    public func record(_ message: ActivityMessage, seen: Bool, dotWaits: Bool = false) {
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
        // A stop the reader asked for is not a problem they missed.
        if message.severity != .success, !message.isStopped, !seen {
            if dotWaits, !hasUnseenProblem { dotHeldFor = message.id }
            hasUnseenProblem = true
        }
    }

    /// The held problem's message went into Activity — landed, or was replaced or cleared, which
    /// must not lose its dot.
    public func releaseDot() {
        if dotHeldFor != nil { dotHeldFor = nil }
    }

    /// Releases the hold only if it is `messageID`'s: one message's landing or leaving must not
    /// show the dot of another still in the capsule.
    public func releaseDot(heldFor messageID: UUID) {
        if dotHeldFor == messageID { dotHeldFor = nil }
    }

    /// Flashes `messageID`'s row once — a repeat folded into an earlier row is that row.
    public func flashRow(for messageID: UUID) {
        flashedRow = recent.first { $0.foldedIDs.contains(messageID) }?.id ?? messageID
        flashes &+= 1
    }

    /// The window's message, as it was published. `run` is the history run the manager last
    /// recorded — attached once, to the first message after it, and only when it was recorded just
    /// now, so a later message is not linked to an old run's records. A run that ended in an alert
    /// posts no message, and the next one may be a rename minutes later. `finishedRun` is the last
    /// long run's minutes, when it ended just now.
    public func record(_ banner: OperationBanner, run: (token: UUID, runId: UUID, recordedAt: Date)?,
                       finishedRun: (started: Date, ended: Date, cancelled: Bool)?, seen: Bool, dotWaits: Bool = false,
                       now: Date = Date()) {
        var runId: UUID?
        if let run, run.token != attachedRunToken, now.timeIntervalSince(run.recordedAt) < Self.runLinkWindow {
            attachedRunToken = run.token
            runId = run.runId
        }
        var start = now.addingTimeInterval(-60)
        var stoppedRun = false
        if let finishedRun, now.timeIntervalSince(finishedRun.ended) < 10 {
            start = min(start, finishedRun.started)
            // Only the run's own ending is its stop — set in the turn its progress cleared, and the
            // first message after it: a delete or a failure a moment later is not.
            if now.timeIntervalSince(finishedRun.ended) < 2, finishedRun.ended != stopClaimedBy {
                stopClaimedBy = finishedRun.ended
                stoppedRun = finishedRun.cancelled
            }
        }
        var message = ActivityMessage(id: banner.id, date: now, message: banner.message, detail: banner.detail,
                                      severity: banner.severity, followUps: banner.followUps,
                                      undoStep: banner.isUndoable ? undoSteps.last : nil, runId: runId,
                                      span: start...now.addingTimeInterval(5))
        message.isStopped = ActivityMessage.isQuietStop(stopped: stoppedRun || ActivityMessage.saysStopped(banner.message),
                                                        message: banner.message, severity: banner.severity)
        record(message, seen: seen, dotWaits: dotWaits)
    }

    /// The history run already linked to a message.
    private var attachedRunToken: UUID?
    /// The ended run whose ending a message already reported — when it ended, which names it.
    private var stopClaimedBy: Date?
    /// How long after its records are written a run's message may still arrive: the records are
    /// written as its undo is registered, before the identity walks of its copies finish.
    static let runLinkWindow: TimeInterval = 30

    /// Edit's own PDF tool and Fill & Sign results, which live on Edit's model rather than in the
    /// window's message (R18). Edit's disk-change and read-only notices are questions, not
    /// messages, and never come here.
    public func record(_ banner: EditorPDFToolBanner, seen: Bool) {
        let result = PaneToolResult(banner, host: PanePDFToolHost())
        var message = ActivityMessage(message: result.banner.message, detail: result.banner.detail,
                                      severity: result.banner.severity, followUps: result.banner.followUps,
                                      source: .edit)
        message.isStopped = ActivityMessage.isQuietStop(stopped: ActivityMessage.saysStopped(result.banner.message),
                                                        message: result.banner.message, severity: result.banner.severity)
        record(message, seen: seen)
    }

    public func clear() {
        recent = []
        hasUnseenProblem = false
        dotHeldFor = nil
    }

    /// Activity was opened: whatever problem was waiting has been seen.
    public func markSeen() {
        if hasUnseenProblem { hasUnseenProblem = false }
        releaseDot()
    }

    /// The Activity window on Now, with `id`'s row picked out (TE227, R15).
    public func openWindow(highlighting id: UUID?) {
        // A repeat folded into an earlier row is that row.
        highlighted = id.map { id in recent.first { $0.foldedIDs.contains(id) }?.id ?? id }
        tab = .now
        markSeen()
        windowRequests += 1
    }

    /// Opens the window's tab the button and ⌘L reopen: the last one used, or Now while a problem
    /// waits (CT).
    public func tabForOpening() -> ActivityTab {
        if hasUnseenProblem { tab = .now }
        return tab
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

/// The Activity window's three tabs (decision CR).
public enum ActivityTab: String, CaseIterable, Identifiable, Sendable {
    case now, history, log

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .now: return "Now"
        case .history: return "History"
        case .log: return "Log"
        }
    }
}
