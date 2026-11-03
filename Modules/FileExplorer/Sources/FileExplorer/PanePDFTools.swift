import AppKit
import Combine
import PDFToolkitCore
import SwiftUI
import Design
import Events
import Sync

/// What the window does around a pane-launched run's copies — the half that needs the app.
public struct PanePDFToolHost {
    /// A copy landed at this path: the panes showing its folder re-read. A batch calls it once per
    /// folder it wrote into, not once per copy.
    public var didWrite: (String) -> Void
    /// The banner's Open — the copy in Edit.
    public var open: (String) -> Void
    /// The banner's Reveal in Browse — the one copy, or a batch's copies.
    public var reveal: ([String]) -> Void
    /// Download, for a file only in the cloud now (TE185) — Edit's own.
    public var download: (String) -> Void

    public init(didWrite: @escaping (String) -> Void = { _ in },
                open: @escaping (String) -> Void = { _ in },
                reveal: @escaping ([String]) -> Void = { _ in },
                download: @escaping (String) -> Void = { _ in }) {
        self.didWrite = didWrite
        self.open = open
        self.reveal = reveal
        self.download = download
    }
}

/// **The PDF tools, run from a pane's row menu** — one window-level owner for whichever run the
/// menu started last.
///
/// **One file is Edit's own ``EditorPDFTools``**, a fresh instance attached to the row's path
/// rather than to an open document: the same refusals, the same fidelity confirmation, the same
/// sheets, the same copy writer and the same banner, so a Compress from Browse and a Compress
/// from Edit's Tools menu are one code path. What the document's load reads before Edit's menu
/// is offered — the page count and the protection — is read here the same way, in the lane, before
/// any sheet opens.
///
/// **Several files are an ``EditorPDFBatch``.** One run at a time across both: a second request
/// while one is in flight is refused in the running one's banner, as Edit refuses one.
@MainActor
public final class PanePDFTools: ObservableObject {

    public enum Current {
        case single(EditorPDFTools)
        case batch(EditorPDFBatch)
        /// Combine several into one, or split one into several (TE294).
        case combineSplit(EditorPDFCombineSplit)
    }

    /// The run the window shows — its sheet, its progress, its banner.
    @Published public private(set) var current: Current?
    /// Set by the window before each request.
    public var host = PanePDFToolHost()
    /// Between a request and its lane read — a second request then is refused too.
    private var preparing = false
    /// The request's own work — the lane read and, for Rotate, the run. Kept so a test can await
    /// it; nothing in the app does.
    private(set) var work: Task<Void, Never>?
    /// Whether a file's bytes are still only in the cloud, asked again when the request is made —
    /// a test's to answer.
    var isCloudOnly: @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }

    public init() {}

    public var isBusy: Bool {
        if preparing { return true }
        switch current {
        // A sheet that is up and not yet run counts: the menu bar's File ▸ PDF Tools stays live
        // over it, and a second request replaced `current` — taking the sheet, and the password
        // half-typed into it, down with it.
        case .single(let tools): return tools.running != nil || tools.sheet != nil
        // A batch's sheet is up from the request until its run starts; the run itself is in the
        // capsule (CH).
        case .batch(let batch): return batch.isRunning || batch.showsSheet
        case .combineSplit(let run): return run.isRunning || run.showsSheet || run.isPreparing
        case nil: return false
        }
    }

    /// **⌘Q asks about a pane's run too**, as it asks about the open PDF's — a batch part-way, a
    /// Compress in its lane, or a sheet with a password half-typed was ended with no question.
    /// It only asks, as the open PDF's question does: a later question in the quit can still keep
    /// the app running, and the run must still be there if it does. The quit itself ends it; copies
    /// already written stay, a copy part-written is a staged file the orphan sweep takes, and the
    /// originals are untouched.
    public func mayQuit() -> Bool {
        guard isBusy else { return true }
        let go = confirmQuit()
        Logger.shared.info("PDF Tools asked before quitting with a run in progress"
                           + (go ? " — the reader chose to quit" : " — the reader stayed"))
        return go
    }

    /// Asks whether to quit over a run — a native alert in the app, a canned answer in a test.
    var confirmQuit: @MainActor () -> Bool = { PanePDFTools.confirmQuitWithAlert() }

    static let quitQuestion = (title: "Stop PDF Tools and quit?",
                               detail: "A PDF tool started from a file pane or Ask Claude is still running, or waiting for its options. "
                                   + "Quitting stops it; copies it has already written stay. The original files are unchanged either way.",
                               go: "Stop and Quit")

    /// Esc cancels and Return does nothing, as in the open PDF's (TE184).
    static func quitAlert() -> NSAlert { EditorPDFTools.leaveAlert(quitQuestion) }

    static func confirmQuitWithAlert() -> Bool { quitAlert().runModal() == .alertFirstButtonReturn }

    /// The request a row's menu made, over `paths` — one file, or several for the three tools
    /// that run over several. `writer` names the workspace in the log ("PDF Tools in Browse").
    public func start(_ request: PDFToolRequest, paths: [String], writer: String) {
        guard !paths.isEmpty, paths.count == 1 || request.runsOnSeveral else { return }
        guard !isBusy else {
            refuseWhileBusy()
            return
        }
        switch request {
        case .combine:
            guard paths.count > 1 else { return }
            startCombineSplit(.combine(paths), writer: writer)
        case .split:
            startCombineSplit(.split(paths[0]), writer: writer)
        default:
            if paths.count == 1 {
                startSingle(request, path: paths[0], writer: writer)
            } else {
                startBatch(request, paths: paths, writer: writer)
            }
        }
    }

    /// Combine or Split: its sheet, after Split's lane read.
    private func startCombineSplit(_ job: EditorPDFCombineSplit.Job, writer: String) {
        let run = EditorPDFCombineSplit(job: job, writer: writer)
        run.host = host
        run.isCloudOnly = isCloudOnly
        current = .combineSplit(run)
        run.prepare()
        work = run.work
    }

    private func refuseWhileBusy() {
        let note = EditorPDFToolBanner(message: EditorPDFTools.busyMessage, kind: .note)
        switch current {
        case .single(let tools): tools.banner = note
        case .batch(let batch): batch.banner = note
        case .combineSplit(let run): run.banner = note
        case nil: break
        }
    }

    // MARK: One file

    private func startSingle(_ request: PDFToolRequest, path: String, writer: String) {
        let tools = EditorPDFTools()
        tools.writer = writer
        tools.isCloudOnly = isCloudOnly
        let host = self.host
        tools.host = EditorPDFToolHost(didWrite: host.didWrite, open: host.open, reveal: { host.reveal([$0]) },
                                       download: host.download)
        current = .single(tools)
        // Evicted since the menu was built: PDFKit opening the placeholder would download it,
        // which nobody asked for.
        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) {
            tools.banner = EditorPDFToolBanner(
                message: EditorPDFTools.cloudOnlyReason((path as NSString).lastPathComponent),
                kind: .note, download: path)
            return
        }
        preparing = true
        work = Task { @MainActor in
            let probe = await EditorPDFToolEngine.probe(URL(fileURLWithPath: EditorFileStore.resolved(path)))
            preparing = false
            Self.offer(request, on: tools, path: path, probe: probe)
            if case .rotateAll(let turns) = request, tools.offersPageTools {
                await tools.run(.rotate(pages: Array(0..<tools.pageCount), quarterTurns: turns))
            }
        }
    }

    /// Attaches the file as the lane read it, then raises the sheet the request names — or says,
    /// in the banner, why the request no longer fits the file. The menu read the protection from
    /// CoreGraphics when it was built; the file may have changed since, and this is the answer that
    /// decides.
    static func offer(_ request: PDFToolRequest, on tools: EditorPDFTools, path: String,
                      probe: EditorPDFToolEngine.Probe) {
        let name = (path as NSString).lastPathComponent
        guard case .facts(let pageCount, let encryption, let droppedParts) = probe else {
            tools.banner = EditorPDFToolBanner(message: unreadableReason(name), kind: .failure)
            return
        }
        tools.attach(path: path, pageCount: pageCount, encryption: encryption, droppedParts: droppedParts)
        func refuse(_ message: String) { tools.banner = EditorPDFToolBanner(message: message, kind: .note) }
        switch request {
        case .rotateAll:
            if !tools.offersPageTools { refuse(tools.disabledReason ?? "“\(name)” has no pages to rotate.") }
        case .compress:
            if tools.offersPageTools { tools.sheet = .compress } else {
                refuse(tools.disabledReason ?? "“\(name)” has no pages to compress.")
            }
        case .cleanMetadata:
            if tools.offersMetadata { tools.sheet = .metadata } else {
                refuse(tools.disabledReason ?? EditorPDFTools.metadataEncryptedReason)
            }
        case .protect:
            if tools.offersProtect { tools.sheet = .protect } else {
                refuse(tools.disabledReason ?? "“\(name)” already has a password. Remove it first.")
            }
        case .removePassword:
            if tools.offersRemovePassword { tools.sheet = .removePassword } else {
                refuse("“\(name)” has no password to remove.")
            }
        // Their own run, never this one's (``startCombineSplit(_:writer:)``).
        case .combine, .split:
            break
        }
    }

    // MARK: From a request (TE294)

    /// **A whole tool, asked for with its options already chosen** — by an Ask Claude card, with
    /// no menu, no sheet and no alert. The same probe, the same instance kind and the same run as a
    /// menu's, on ``current``, so it is busy, in the capsule and asked about at ⌘Q like any other.
    ///
    /// What the menu's ``offer(_:on:path:probe:)`` refuses is refused here too, in its words: the
    /// run itself does not check a file's protection. `expecting` is the stamp the asker read: a
    /// file that changed since is refused, in words that promise no reload. `allow` answers the
    /// form question the alert would have asked — whether the loss the run found is the one the
    /// asker showed. The copy goes into `folder` when given, else beside the original.
    ///
    /// The ending never reaches ``PanePDFSingleLayer``: it goes to `completion`. A menu request
    /// while this runs is refused in the pane, as it is during any run.
    public func startFromChat(_ tool: EditorPDFTool, path: String, folder: String? = nil,
                              expecting: EditorFileStore.Stamp?, writer: String,
                              allow: @escaping @MainActor (OutputFidelityWarning) -> Bool,
                              completion: @escaping @MainActor (PDFRunResult) -> Void) {
        guard !isBusy else {
            completion(.busy)
            return
        }
        let tools = EditorPDFTools()
        tools.writer = writer
        tools.isCloudOnly = isCloudOnly
        tools.quiet = true
        tools.destinationFolder = folder
        tools.confirm = { warning, _ in allow(warning) }
        tools.changedMessage = Self.changedSinceAskedReason
        let host = self.host
        tools.host = EditorPDFToolHost(didWrite: host.didWrite, open: host.open, reveal: { host.reveal([$0]) },
                                       download: host.download)
        current = .single(tools)
        let name = (path as NSString).lastPathComponent
        if isCloudOnly(MaterializationStatus.linkTarget(of: path)) {
            completion(PDFRunResult(outcome: .failed, message: EditorPDFTools.cloudOnlyReason(name), download: path))
            return
        }
        preparing = true
        work = Task { @MainActor in
            let probe = await EditorPDFToolEngine.probe(URL(fileURLWithPath: EditorFileStore.resolved(path)))
            preparing = false
            guard case .facts(let pageCount, let encryption, let droppedParts) = probe else {
                completion(PDFRunResult(outcome: .failed, message: Self.unreadableReason(name)))
                return
            }
            tools.attach(path: path, pageCount: pageCount, encryption: encryption, droppedParts: droppedParts)
            if let refusal = Self.refusal(tool, on: tools, name: name) {
                completion(PDFRunResult(outcome: .failed, message: refusal))
                return
            }
            tools.shownStamp = expecting
            let outcome = await tools.run(tool)
            completion(Self.result(outcome, tools: tools, path: path))
        }
    }

    /// **Several files, one whole-file tool** — a batch asked for by a request, as
    /// ``startFromChat(_:path:folder:expecting:writer:allow:completion:)`` is for one. `expecting`
    /// holds each file's stamp as the asker read it; `allow` answers the batch's one form question.
    public func startBatchFromChat(_ tool: EditorPDFBatchTool, paths: [String], folder: String? = nil,
                                   expecting: [String: EditorFileStore.Stamp], writer: String,
                                   allow: @escaping @MainActor (EditorPDFBatchWarning) -> Bool,
                                   completion: @escaping @MainActor (PDFRunResult) -> Void) {
        guard !isBusy else {
            completion(.busy)
            return
        }
        guard !paths.isEmpty else {
            completion(PDFRunResult(outcome: .failed, message: "No files were given."))
            return
        }
        let kind: EditorPDFBatchKind
        switch tool {
        case .rotate(let turns): kind = .rotate(quarterTurns: turns)
        case .compress: kind = .compress
        case .cleanMetadata: kind = .cleanMetadata
        }
        let batch = EditorPDFBatch(kind: kind, paths: paths, writer: writer)
        batch.host = host
        batch.isCloudOnly = isCloudOnly
        batch.quiet = true
        batch.destinationFolder = folder
        batch.expected = expecting
        batch.confirm = allow
        current = .batch(batch)
        // Busy from now, as a menu's Rotate is: no sheet is up to say so.
        preparing = true
        work = Task { @MainActor in
            preparing = false
            let outcome = await batch.run(tool)
            completion(Self.result(outcome, batch: batch))
        }
    }

    /// **Combine or Split, asked for by a request** — the menu's run with the sheet's choices
    /// already made: Combine's files in their order under `name`, Split's parts starting at
    /// `splitAt` (one-based). No sheet; the ending goes to `completion`. `expecting` holds each
    /// file's stamp as the asker read it.
    public func startCombineSplitFromChat(_ job: EditorPDFCombineSplit.Job, name: String? = nil, splitAt: [Int] = [],
                                          folder: String? = nil,
                                          expecting: [String: EditorFileStore.Stamp], writer: String,
                                          completion: @escaping @MainActor (PDFRunResult) -> Void) {
        guard !isBusy else {
            completion(.busy)
            return
        }
        if case .combine(let paths) = job, Set(paths).count < 2 || Set(paths).count != paths.count {
            completion(PDFRunResult(outcome: .failed, message: "Combine needs two or more different PDFs."))
            return
        }
        let run = EditorPDFCombineSplit(job: job, writer: writer)
        run.host = host
        run.isCloudOnly = isCloudOnly
        run.quiet = true
        run.expected = expecting
        run.destinationFolder = folder
        if let name { run.name = name }
        run.splitAt = splitAt.map(String.init).joined(separator: ", ")
        current = .combineSplit(run)
        preparing = true
        work = Task { @MainActor in
            run.prepare()
            await run.work?.value
            preparing = false
            // Split's lane read said why not, if it can't split: that is the ending.
            if let said = run.prepareRefusal {
                completion(PDFRunResult(outcome: .failed, message: said.message, download: said.download))
                return
            }
            if case .split = job, case .failure(let problem) = EditorPDFCombineSplit.parts(run.splitAt, pageCount: run.pageCount) {
                completion(PDFRunResult(outcome: .failed, message: problem.sentence))
                return
            }
            if case .combine = job, case .failure(let problem) = EditorPDFCombineSplit.fileName(run.name) {
                completion(PDFRunResult(outcome: .failed, message: problem.sentence))
                return
            }
            await run.run()
            completion(Self.result(run))
        }
    }

    static func result(_ run: EditorPDFCombineSplit) -> PDFRunResult {
        let said = run.lastReport
        let outcome: PDFRunResult.Outcome
        if !run.written.isEmpty {
            outcome = run.written.count == run.asked ? .wrote : .partlyWrote
        } else if case .failure? = said?.kind {
            outcome = .failed
        } else {
            outcome = run.asked == 0 ? .failed : .cancelled
        }
        return PDFRunResult(outcome: outcome, written: run.written, message: said?.message ?? "",
                            detail: said?.detail, download: said?.download)
    }

    /// What the menu's ``offer(_:on:path:probe:)`` refuses, for a whole tool on an attached file —
    /// `nil` when it may run. Fill & Sign is Edit's alone: it is never asked for from a request.
    static func refusal(_ tool: EditorPDFTool, on tools: EditorPDFTools, name: String) -> String? {
        switch tool {
        case .rotate, .deletePages, .reorder, .extract, .compress, .arranged:
            return tools.offersPageTools ? nil : tools.disabledReason ?? "“\(name)” has no pages."
        case .cleanMetadata:
            return tools.offersMetadata ? nil : tools.disabledReason ?? EditorPDFTools.metadataEncryptedReason
        case .protect:
            return tools.offersProtect ? nil : tools.disabledReason ?? "“\(name)” already has a password. Remove it first."
        case .removePassword:
            return tools.offersRemovePassword ? nil : "“\(name)” has no password to remove."
        case .fillAndSign, .fillForm:
            return "Fill & Sign runs only in Edit."
        }
    }

    /// Edit's sentence promises a reload; a request's file is not open anywhere.
    static func changedSinceAskedReason(_ name: String) -> String {
        "“\(name)” changed since it was chosen, so nothing was written."
    }

    static func unreadableReason(_ name: String) -> String {
        "Couldn’t read “\(name)” as a PDF, so no tool can run on it. It may be damaged — Preview may still open it."
    }

    static func result(_ outcome: EditorPDFToolOutcome, tools: EditorPDFTools, path: String) -> PDFRunResult {
        let said = tools.lastReport
        switch outcome {
        case .wrote:
            return PDFRunResult(outcome: .wrote, written: tools.lastWrite.map { [$0] } ?? [],
                                message: said?.message ?? "", detail: said?.detail)
        case .nothingWritten(let message):
            return PDFRunResult(outcome: .nothingWritten, message: message)
        case .cancelled:
            return PDFRunResult(outcome: .cancelled, message: said?.message ?? "Canceled — nothing was written.")
        case .declined:
            return PDFRunResult(outcome: .declined, message: "What this copy would lose has changed, so nothing was written.")
        case .failed(let message):
            return PDFRunResult(outcome: .failed, message: message, download: said?.download)
        }
    }

    static func result(_ outcome: EditorPDFBatch.Outcome, batch: EditorPDFBatch) -> PDFRunResult {
        switch outcome {
        case .busy: return .busy
        case .declined:
            return PDFRunResult(outcome: .declined, message: "What these copies would lose has changed, so nothing was written.")
        case .finished: break
        }
        var skipped: [PDFRunResult.Skipped] = []
        var failed = false, cancelled = false, small = 0
        for file in batch.files {
            switch file.status {
            case .wrote, .waiting, .running: break
            case .skipped(let skip):
                if skip == .cancelled { cancelled = true }
                if skip == .alreadySmall { small += 1 }
                skipped.append(.init(path: file.path, reason: skip.reason))
            case .failed(let reason):
                failed = true
                skipped.append(.init(path: file.path, reason: reason))
            }
        }
        let written = batch.written
        let kind: PDFRunResult.Outcome
        if !written.isEmpty {
            kind = skipped.isEmpty ? .wrote : .partlyWrote
        } else if cancelled {
            kind = .cancelled
        } else if failed {
            kind = .failed
        } else {
            kind = small == skipped.count ? .nothingWritten : .failed
        }
        return PDFRunResult(outcome: kind, written: written, skipped: skipped,
                            message: batch.lastReport?.message ?? "", detail: batch.lastReport?.detail)
    }

    // MARK: Several files

    private func startBatch(_ request: PDFToolRequest, paths: [String], writer: String) {
        let kind: EditorPDFBatchKind
        switch request {
        case .rotateAll(let turns): kind = .rotate(quarterTurns: turns)
        case .compress: kind = .compress
        case .cleanMetadata: kind = .cleanMetadata
        case .protect, .removePassword, .combine, .split: return
        }
        let batch = EditorPDFBatch(kind: kind, paths: paths, writer: writer)
        batch.host = host
        batch.isCloudOnly = isCloudOnly
        current = .batch(batch)
        // Rotate asks nothing, so it opens no sheet: its run goes straight to the capsule (CH).
        // Busy from now, not from its first turn — with no sheet up to say so, a second request in
        // between would replace it.
        if case .rotate(let turns) = kind {
            preparing = true
            work = Task { @MainActor in
                preparing = false
                await batch.run(.rotate(quarterTurns: turns))
            }
        } else {
            batch.showsSheet = true
        }
    }
}

// MARK: - The window's half

/// **Where a pane-launched run shows itself**: its sheet over the window, its progress at the foot
/// of the window — the same ``EditorPDFToolSheetView`` and the same strip Edit's card draws — and
/// its ending as the pane's result message (Banner Room, TE207): each banner the run sets is handed
/// to `onResult` as a ``PaneToolResult`` and taken off the model, so the foot only ever shows a run
/// in progress.
///
/// **A real `.sheet`, not an entry in the window's overlay chain.** The chain is a priority list
/// of full-window panels that yield to one another — Settings or Help opening covers whatever is
/// below it, and that one comes back when they close. A tool's sheet must not yield: its run is in
/// the lane, and its Cancel is the only way to stop it. A sheet is window-modal, so nothing can
/// cover it mid-run, and it is what Edit already presents these exact views in, so they look the
/// same from a pane as from Edit's Tools menu.
///
/// **Save as PDF's progress stands above the tools' in the same column** (``PaneSaveAsPDFLayer``),
/// so the two never draw over each other at the window's foot.
public struct PanePDFToolsPresenter: ViewModifier {
    let model: PanePDFTools
    let saveAsPDF: PaneSaveAsPDF?
    let accent: Color
    let onResult: (PaneToolResult) -> Void

    public init(model: PanePDFTools, saveAsPDF: PaneSaveAsPDF? = nil, accent: Color,
                onResult: @escaping (PaneToolResult) -> Void) {
        self.model = model
        self.saveAsPDF = saveAsPDF
        self.accent = accent
        self.onResult = onResult
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let saveAsPDF {
                    PaneSaveAsPDFLayer(model: saveAsPDF, accent: accent, onResult: onResult)
                }
                PanePDFToolsLayer(model: model, accent: accent, onResult: onResult)
            }
        }
    }
}

/// Observes the window's model — the window itself does not, so a run's progress re-renders this
/// layer and nothing above it.
struct PanePDFToolsLayer: View {
    @ObservedObject var model: PanePDFTools
    let accent: Color
    let onResult: (PaneToolResult) -> Void

    var body: some View {
        switch model.current {
        case .single(let tools):
            PanePDFSingleLayer(tools: tools, host: model.host, accent: accent, onResult: onResult)
        case .batch(let batch):
            PanePDFBatchLayer(batch: batch, accent: accent, onResult: onResult)
        case .combineSplit(let run):
            PanePDFCombineSplitLayer(run: run, onResult: onResult)
        case nil:
            EmptyView()
        }
    }
}

struct PanePDFSingleLayer: View {
    @ObservedObject var tools: EditorPDFTools
    /// The window's doors, which reveal a list — `tools.host` is Edit's, which reveals one path.
    let host: PanePDFToolHost
    let accent: Color
    let onResult: (PaneToolResult) -> Void

    var body: some View {
        // A stack rather than a `Group`: with nothing to say a `Group` is no view at all, and the
        // sheet below would have nothing to hang from.
        VStack(spacing: 0) {
            // Nothing drawn here: a run in flight shows in the toolbar's capsule with its Stop (TE207,
            // ``RunCapsuleHost``), and its ending is the pane's result message, handed over below.
        }
        // `initial`: a banner set before this layer mounted — a cloud-only file refused in the same
        // turn the run was made — is handed over too. Cleared once handed, so a remount cannot
        // post it twice.
        .onChange(of: tools.banner, initial: true) { _, banner in
            guard let banner else { return }
            onResult(PaneToolResult(banner, host: host))
            tools.banner = nil
        }
        .background {
            Color.clear.sheet(item: $tools.sheet) { sheet in
                EditorPDFToolSheetView(tools: tools, sheet: sheet).presentedNativeControlAccent()
            }
        }
    }
}

struct PanePDFBatchLayer: View {
    @ObservedObject var batch: EditorPDFBatch
    let accent: Color
    let onResult: (PaneToolResult) -> Void

    var body: some View {
        // A stack rather than a `Group`, for the sheet's sake — see ``PanePDFSingleLayer``. The sheet
        // asks its question and closes; the run shows in the toolbar's capsule (CH), and its ending
        // is the pane's result message.
        VStack(spacing: 0) {}
        .onChange(of: batch.banner, initial: true) { _, banner in
            guard let banner else { return }
            onResult(PaneToolResult(banner, host: batch.host))
            batch.banner = nil
        }
        .background {
            Color.clear.sheet(isPresented: $batch.showsSheet) {
                EditorPDFBatchSheet(batch: batch)
                    .padding(20)
                    // A floor, not a fixed width — the tool sheets' own (TE134).
                    .frame(minWidth: EditorPDFBatchSheet.minWidth, idealWidth: EditorPDFBatchSheet.idealWidth)
                    // No `.accentedProminent()` here: a root tint draws every bordered button's
                    // words in the fill. The sheet's default button takes it itself.
                    .presentedNativeControlAccent()
            }
        }
    }
}

/// Combine's and Split's sheet over the window, and their ending as the pane's result message — the
/// batch's shape (``PanePDFBatchLayer``).
struct PanePDFCombineSplitLayer: View {
    @ObservedObject var run: EditorPDFCombineSplit
    let onResult: (PaneToolResult) -> Void

    var body: some View {
        VStack(spacing: 0) {}
        .onChange(of: run.banner, initial: true) { _, banner in
            guard let banner else { return }
            onResult(PaneToolResult(banner, host: run.host))
            run.banner = nil
        }
        .background {
            Color.clear.sheet(isPresented: $run.showsSheet) {
                EditorPDFCombineSplitSheet(run: run)
                    .padding(20)
                    .frame(minWidth: EditorPDFBatchSheet.minWidth, idealWidth: EditorPDFBatchSheet.idealWidth)
                    .presentedNativeControlAccent()
            }
        }
    }
}

/// A run's progress strip's backing at the window's foot — Edit's row draws on the card's own
/// surface; here it floats over the panes, so it carries its own, at the scale's floating-card radius.
struct PanePDFToolCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.bottom, 44)
    }
}
