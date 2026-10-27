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
                               detail: "A PDF tool started from a file pane is still running, or waiting for its options. "
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
        if paths.count == 1 {
            startSingle(request, path: paths[0], writer: writer)
        } else {
            startBatch(request, paths: paths, writer: writer)
        }
    }

    private func refuseWhileBusy() {
        let note = EditorPDFToolBanner(message: EditorPDFTools.busyMessage, kind: .note)
        switch current {
        case .single(let tools): tools.banner = note
        case .batch(let batch): batch.banner = note
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
            tools.banner = EditorPDFToolBanner(message: "Couldn’t read “\(name)” as a PDF, so no tool can run on it. "
                                               + "It may be damaged — Preview may still open it.",
                                               kind: .failure)
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
        }
    }

    // MARK: Several files

    private func startBatch(_ request: PDFToolRequest, paths: [String], writer: String) {
        let kind: EditorPDFBatchKind
        switch request {
        case .rotateAll(let turns): kind = .rotate(quarterTurns: turns)
        case .compress: kind = .compress
        case .cleanMetadata: kind = .cleanMetadata
        case .protect, .removePassword: return
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
