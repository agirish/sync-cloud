import SwiftUI
import Design

/// **Every run the window shows progress for, in the toolbar's capsule** (TE205, TE207's run
/// half): the long file operation on `FileSyncManager.activeProgress`, a PDF tool run from a pane's
/// menu, and Save as PDF. Their *results* stay with the pane, not here (BY).
///
/// **The capsule draws the newest run** (TE218, decision CI) — the one just asked for. With two or
/// more, its ✕ gives way to a count that opens ``ProgressCapsuleRunList``, where every run has its
/// own Stop (TE217, TE219). It used to draw the first of the three in a fixed order with the others
/// a grey "+1": a Save as PDF behind a merge then had no Stop anywhere until the merge ended.
///
/// A pane-launched batch is not here: its sheet carries its own per-file progress and its Cancel,
/// window-modal by design (``PanePDFToolsPresenter``).
public struct RunCapsuleHost: View {
    let activeProgress: Progress?
    let activeProgressStartedAt: Date?
    @ObservedObject var pdfTools: PanePDFTools
    @ObservedObject var saveAsPDF: PaneSaveAsPDF
    let style: ProgressCapsuleStyle
    /// The list of runs, open under the capsule.
    @State private var showsRuns = false

    public init(activeProgress: Progress?, activeProgressStartedAt: Date?, pdfTools: PanePDFTools,
                saveAsPDF: PaneSaveAsPDF, style: ProgressCapsuleStyle) {
        self.activeProgress = activeProgress
        self.activeProgressStartedAt = activeProgressStartedAt
        self.pdfTools = pdfTools
        self.saveAsPDF = saveAsPDF
        self.style = style
    }

    public var body: some View {
        if case .single(let tools) = pdfTools.current {
            RunCapsuleObserving(model: tools) { tools in
                capsule(pdfRun: RunCapsuleEntry.pdfTool(tools))
            }
        } else {
            capsule(pdfRun: nil)
        }
    }

    @ViewBuilder private func capsule(pdfRun: RunCapsuleEntry?) -> some View {
        let entries = RunCapsuleEntry.newestFirst(
            [activeProgress.map { RunCapsuleEntry.fileOperation($0, startedAt: activeProgressStartedAt) },
             pdfRun, RunCapsuleEntry.saveAsPDF(saveAsPDF)].compactMap { $0 })
        if let newest = entries.first {
            // An `NSProgress` is not observable, so the snapshot is taken again ten times a second
            // while a run is up — the dialog's own cadence — and not at all once it ends.
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                ProgressCapsule(run: newest.snapshot(), style: style,
                                othersRunning: entries.dropFirst().map { $0.snapshot().summary },
                                onCancel: newest.cancel,
                                onShowRuns: { showsRuns = true })
            }
            .popover(isPresented: $showsRuns, arrowEdge: .bottom) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    ProgressCapsuleRunList(runs: entries.map { $0.listed() })
                }
                .presentedNativeControlAccent()
            }
            // The last other run ended with the list open: one run is left, and the capsule's own
            // ✕ stops it again.
            .onChange(of: entries.count) { _, count in if count < 2 { showsRuns = false } }
        }
    }
}

/// Whether any pane-launched run is showing in the capsule — what the toolbar needs to know to
/// seat it, observed here so the window itself need not observe the PDF models (it does not; a
/// run's progress would otherwise re-render the whole window).
public struct RunCapsulePresence: View {
    @ObservedObject var pdfTools: PanePDFTools
    @ObservedObject var saveAsPDF: PaneSaveAsPDF
    let onChange: (Bool) -> Void

    public init(pdfTools: PanePDFTools, saveAsPDF: PaneSaveAsPDF, onChange: @escaping (Bool) -> Void) {
        self.pdfTools = pdfTools
        self.saveAsPDF = saveAsPDF
        self.onChange = onChange
    }

    public var body: some View {
        if case .single(let tools) = pdfTools.current {
            RunCapsuleObserving(model: tools) { tools in
                report(RunCapsuleEntry.pdfTool(tools) != nil)
            }
        } else {
            report(false)
        }
    }

    private func report(_ pdfRunning: Bool) -> some View {
        let showing = pdfRunning || saveAsPDF.isRunning
        return Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: showing, initial: true) { _, now in onChange(now) }
    }
}

/// One run's snapshot and its stop — read through closures so the capsule's timeline re-reads the
/// live values on every tick.
struct RunCapsuleEntry {
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
    let cancel: (() -> Void)?

    /// Newest first (decision CI). A run with no start time sorts as the oldest; ties keep the
    /// kinds' own order, so the answer never depends on the order they were handed in.
    static func newestFirst(_ entries: [RunCapsuleEntry]) -> [RunCapsuleEntry] {
        entries.sorted { lhs, rhs in
            let left = lhs.startedAt ?? .distantPast, right = rhs.startedAt ?? .distantPast
            return left != right ? left > right : lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    func listed() -> ProgressCapsuleListedRun {
        ProgressCapsuleListedRun(id: "\(kind)", run: snapshot(), symbol: kind.symbol, startedAt: startedAt,
                                 onCancel: cancel)
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
        }, cancel: { tools.cancelRun() })
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
