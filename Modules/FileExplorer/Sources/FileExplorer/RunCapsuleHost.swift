import SwiftUI
import Design

/// **Every run the window shows progress for, in the toolbar's capsule** (TE205, TE207's run
/// half): the long file operation on `FileSyncManager.activeProgress`, a PDF tool run from a pane's
/// menu, and Save as PDF. Their *results* stay with the pane, not here (BY).
///
/// **The capsule draws the newest run** (TE218, decision CI) — the one just asked for. With two or
/// more, its ✕ gives way to a count (TE217, TE219). It used to draw the first of the three in a fixed
/// order with the others a grey "+1": a Save as PDF behind a merge then had no Stop anywhere until
/// the merge ended.
///
/// **A click on it opens Activity** (TE220, decision CK as CR left it): every run with its own Stop,
/// and Recent, in a popover under the capsule. While that is open the capsule stays, reading
/// "Nothing running" once the last run ends, so the popover is not taken away with it (TE231).
///
/// A pane-launched batch is here too, once its sheet has asked its question (decision CH): it ran
/// in a window-modal sheet that locked the window for the length of the batch.
public struct RunCapsuleHost: View {
    let activeProgress: Progress?
    let activeProgressStartedAt: Date?
    @ObservedObject var center: ActivityCenter
    let runWriteLock: String?
    /// The long scans, listed under the runs in the popover — never in the capsule (TE228).
    let scans: [ProgressCapsuleListedRun]
    /// A run's ending bound for the capsule (CG), over whatever runs (CU).
    let message: ProgressCapsuleMessage?
    let style: ProgressCapsuleStyle
    @Environment(\.openWindow) private var openWindow

    public init(activeProgress: Progress?, activeProgressStartedAt: Date?, center: ActivityCenter,
                runWriteLock: String?, scans: [ProgressCapsuleListedRun] = [],
                message: ProgressCapsuleMessage? = nil, style: ProgressCapsuleStyle) {
        self.activeProgress = activeProgress
        self.activeProgressStartedAt = activeProgressStartedAt
        self.center = center
        self.runWriteLock = runWriteLock
        self.scans = scans
        self.message = message
        self.style = style
    }

    public var body: some View {
        ActivityRunsReader(activeProgress: activeProgress, activeProgressStartedAt: activeProgressStartedAt,
                           center: center) { entries in
            capsule(entries)
        }
    }

    @ViewBuilder private func capsule(_ entries: [RunCapsuleEntry]) -> some View {
        let open = { center.markSeen(); center.popoverIsOpen = true }
        Group {
            if let newest = entries.first {
                // An `NSProgress` is not observable, so the snapshot is taken again ten times a
                // second while a run is up — the dialog's own cadence — and not at all once it ends.
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    ProgressCapsule(run: newest.snapshot(), style: style,
                                    othersRunning: entries.dropFirst().map { $0.snapshot().summary },
                                    onCancel: newest.cancel, onShowRuns: open, onOpen: open, message: message)
                }
            } else {
                ProgressCapsule(run: .idle, style: style, onCancel: nil, onOpen: open, message: message)
            }
        }
        .popover(isPresented: $center.popoverIsOpen, arrowEdge: .bottom) {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                ActivityNowView(runs: entries.map { $0.listed() } + scans, center: center, runWriteLock: runWriteLock,
                                now: timeline.date,
                                onOpenWindow: {
                                    center.popoverIsOpen = false
                                    center.tab = .now
                                    openWindow(id: ActivityCenter.windowID)
                                })
            }
            .presentedNativeControlAccent()
        }
    }
}

/// **Every run going, newest first** — read off the file operation the window publishes and the
/// pane PDF runs ``ActivityCenter`` owns, for the capsule and for Activity's Running rows alike.
public struct ActivityRunsReader<Content: View>: View {
    let activeProgress: Progress?
    let activeProgressStartedAt: Date?
    @ObservedObject var pdfTools: PanePDFTools
    @ObservedObject var saveAsPDF: PaneSaveAsPDF
    let content: ([RunCapsuleEntry]) -> Content

    public init(activeProgress: Progress?, activeProgressStartedAt: Date?, center: ActivityCenter,
                @ViewBuilder content: @escaping ([RunCapsuleEntry]) -> Content) {
        self.activeProgress = activeProgress
        self.activeProgressStartedAt = activeProgressStartedAt
        pdfTools = center.panePDFTools
        saveAsPDF = center.paneSaveAsPDF
        self.content = content
    }

    public var body: some View {
        switch pdfTools.current {
        case .single(let tools):
            RunCapsuleObserving(model: tools) { tools in
                content(entries(pdfRun: RunCapsuleEntry.pdfTool(tools)))
            }
        case .batch(let batch):
            RunCapsuleObserving(model: batch) { batch in
                content(entries(pdfRun: RunCapsuleEntry.batch(batch)))
            }
        case nil:
            content(entries(pdfRun: nil))
        }
    }

    private func entries(pdfRun: RunCapsuleEntry?) -> [RunCapsuleEntry] {
        RunCapsuleEntry.newestFirst(
            [activeProgress.map { RunCapsuleEntry.fileOperation($0, startedAt: activeProgressStartedAt) },
             pdfRun, RunCapsuleEntry.saveAsPDF(saveAsPDF)].compactMap { $0 })
    }
}

/// Whether any pane-launched run is showing in the capsule, and whether Activity is open under it
/// — what the toolbar needs to know to seat it, observed here so the window itself need not observe
/// the PDF models (it does not; a run's progress would otherwise re-render the whole window).
///
/// The popover is reported apart from the runs: it holds the row as it was when it opened (TE231),
/// and is no run of its own — counted as one, a click on a capsule holding only a message folded
/// the workspace names that message had been careful to leave alone (TE230).
public struct RunCapsulePresence: View {
    @ObservedObject var center: ActivityCenter
    @ObservedObject var pdfTools: PanePDFTools
    @ObservedObject var saveAsPDF: PaneSaveAsPDF
    let onChange: (Bool) -> Void
    let onPopoverChange: (Bool) -> Void

    public init(center: ActivityCenter, onChange: @escaping (Bool) -> Void,
                onPopoverChange: @escaping (Bool) -> Void = { _ in }) {
        self.center = center
        pdfTools = center.panePDFTools
        saveAsPDF = center.paneSaveAsPDF
        self.onChange = onChange
        self.onPopoverChange = onPopoverChange
    }

    public var body: some View {
        switch pdfTools.current {
        case .single(let tools):
            RunCapsuleObserving(model: tools) { tools in
                report(RunCapsuleEntry.pdfTool(tools) != nil)
            }
        case .batch(let batch):
            RunCapsuleObserving(model: batch) { batch in
                report(RunCapsuleEntry.batch(batch) != nil)
            }
        case nil:
            report(false)
        }
    }

    private func report(_ pdfRunning: Bool) -> some View {
        let showing = pdfRunning || saveAsPDF.isRunning
        return Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: showing, initial: true) { _, now in onChange(now) }
            .onChange(of: center.popoverIsOpen, initial: true) { _, open in onPopoverChange(open) }
    }
}

/// One run's snapshot and its stop — read through closures so the capsule's timeline re-reads the
/// live values on every tick.
public struct RunCapsuleEntry {
    enum Kind: Int {
        case fileOperation, pdfTool, saveAsPDF

        var symbol: String {
            switch self {
            case .fileOperation: return "doc.on.doc"
            case .pdfTool: return "wrench.and.screwdriver"
            case .saveAsPDF: return "doc.richtext"
            }
        }
    }

    let kind: Kind
    let startedAt: Date?
    let snapshot: () -> ProgressCapsuleRun
    private let currentCancel: () -> (() -> Void)?

    /// The run's Stop as it stands NOW, or nil — re-read on every tick like the snapshot. A run
    /// stops being cancellable when only its undo is left to arm (`markFinishing`), and its Stop
    /// and ⌘. must go with it rather than stay as they were when the run appeared.
    var cancel: (() -> Void)? { currentCancel() }
    /// A PDF run waiting its turn in the app's one PDF lane (R17) — a clock, not its tool.
    let isWaiting: () -> Bool

    /// `cancel` is an autoclosure, so whatever it reads — `progress.isCancellable` — is read each
    /// time ``cancel`` is, not once here.
    init(kind: Kind, startedAt: Date?, snapshot: @escaping () -> ProgressCapsuleRun,
         cancel: @autoclosure @escaping () -> (() -> Void)?, isWaiting: @escaping () -> Bool = { false }) {
        self.kind = kind
        self.startedAt = startedAt
        self.snapshot = snapshot
        self.currentCancel = cancel
        self.isWaiting = isWaiting
    }

    /// Newest first (decision CI). A run with no start time sorts as the oldest; ties keep the
    /// kinds' own order, so the answer never depends on the order they were handed in.
    static func newestFirst(_ entries: [RunCapsuleEntry]) -> [RunCapsuleEntry] {
        entries.sorted { lhs, rhs in
            let left = lhs.startedAt ?? .distantPast, right = rhs.startedAt ?? .distantPast
            return left != right ? left > right : lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    public func listed() -> ProgressCapsuleListedRun {
        ProgressCapsuleListedRun(id: "\(kind)", run: snapshot(), symbol: isWaiting() ? "clock" : kind.symbol,
                                 startedAt: startedAt, onCancel: cancel)
    }

    static func fileOperation(_ progress: Progress, startedAt: Date?) -> RunCapsuleEntry {
        RunCapsuleEntry(kind: .fileOperation, startedAt: startedAt,
                        snapshot: { ProgressCapsuleRun(progress: progress) },
                        cancel: progress.isCancellable ? { progress.cancel() } : nil)
    }

    /// A single PDF tool run from a pane, once its options sheet is closed — while the sheet is up
    /// the run's progress is in it.
    @MainActor static func pdfTool(_ tools: EditorPDFTools) -> RunCapsuleEntry? {
        guard let requested = tools.running, tools.sheet == nil else { return nil }
        return RunCapsuleEntry(kind: .pdfTool, startedAt: requested.requestedAt, snapshot: {
            guard let running = tools.running else { return ProgressCapsuleRun(title: "") }
            let pages = running.reportsProgress ? tools.progress : nil
            return ProgressCapsuleRun(title: EditorPDFToolBannerView.runningMessage(running, progress: nil),
                                      completed: Int64(pages?.page ?? 0), total: Int64(pages?.total ?? 0),
                                      detail: tools.path.map { ($0 as NSString).lastPathComponent },
                                      cancelTitle: "Stop", cancelHelp: "Stop — nothing is written")
        }, cancel: { tools.cancelRun() }, isWaiting: { !(tools.running?.started ?? true) })
    }

    /// **A pane's batch, once its sheet has asked its question** (Run Room CH) — in the one-file
    /// run's slot, since the two share one PDF run (R2): "Compressing 4 PDFs", 2 of 4, the file in
    /// hand and its page, and Stop.
    @MainActor static func batch(_ batch: EditorPDFBatch) -> RunCapsuleEntry? {
        guard batch.isRunning, !batch.showsSheet else { return nil }
        return RunCapsuleEntry(kind: .pdfTool, startedAt: batch.startedAt, snapshot: {
            let title = batchTitle(batch.kind, count: batch.count)
            guard let progress = batch.progress else {
                return ProgressCapsuleRun(title: "\(title) — \(EditorPDFToolBannerView.waitingWords)",
                                          cancelTitle: "Stop", cancelHelp: batchStopHelp)
            }
            let name = batch.files.indices.contains(progress.file - 1) ? batch.files[progress.file - 1].name : nil
            let page = progress.page.flatMap { page in progress.pages.map { "page \(page) of \($0)" } }
            return ProgressCapsuleRun(title: title, completed: Int64(progress.file), total: Int64(progress.files),
                                      detail: [name, page].compactMap { $0 }.joined(separator: " · "),
                                      cancelTitle: "Stop", cancelHelp: batchStopHelp)
        }, cancel: { batch.cancel() }, isWaiting: { batch.progress == nil })
    }

    static let batchStopHelp = "Stop after this file — the copies already written stay"

    /// "Compressing 4 PDFs" — what the run does, and to how many.
    static func batchTitle(_ kind: EditorPDFBatchKind, count: Int) -> String {
        let pdfs = count == 1 ? "1 PDF" : "\(count.formatted()) PDFs"
        switch kind {
        case .rotate: return "Rotating \(pdfs)"
        case .compress: return "Compressing \(pdfs)"
        case .cleanMetadata: return "Cleaning the metadata of \(pdfs)"
        }
    }

    @MainActor static func saveAsPDF(_ model: PaneSaveAsPDF) -> RunCapsuleEntry? {
        guard model.isRunning else { return nil }
        return RunCapsuleEntry(kind: .saveAsPDF, startedAt: model.startedAt, snapshot: {
            guard let progress = model.progress else { return ProgressCapsuleRun(title: "") }
            return ProgressCapsuleRun(title: PaneSaveAsPDFLayer.progressTitle(progress),
                                      completed: Int64(progress.total > 1 ? progress.done : 0),
                                      total: Int64(progress.total > 1 ? progress.total : 0),
                                      detail: progress.name,
                                      cancelTitle: "Stop",
                                      cancelHelp: "Stop after this file — the PDFs already saved stay",
                                      note: model.busyNote)
        // One file has nothing to stop between.
        }, cancel: (model.progress?.total ?? 0) > 1 ? { model.stop() } : nil)
    }
}

/// Observes a nested model the parent holds only by reference, so its changes reach the capsule.
struct RunCapsuleObserving<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    @ViewBuilder let content: (Model) -> Content

    var body: some View { content(model) }
}
