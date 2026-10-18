import AppKit
import Combine
import PDFToolkitCore
import SwiftUI
import Design
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

    public init(didWrite: @escaping (String) -> Void = { _ in },
                open: @escaping (String) -> Void = { _ in },
                reveal: @escaping ([String]) -> Void = { _ in }) {
        self.didWrite = didWrite
        self.open = open
        self.reveal = reveal
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
    var isCloudOnly: (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }

    public init() {}

    public var isBusy: Bool {
        if preparing { return true }
        switch current {
        case .single(let tools): return tools.running != nil
        // A batch's sheet is up from the request to the end of its run — Rotate's included, which
        // opens on its progress before its run has started.
        case .batch(let batch): return batch.isRunning || batch.showsSheet
        case nil: return false
        }
    }

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
        let note = EditorPDFToolBanner(message: "Another tool is still running.", kind: .note)
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
        tools.host = EditorPDFToolHost(didWrite: host.didWrite, open: host.open, reveal: { host.reveal([$0]) })
        current = .single(tools)
        // Evicted since the menu was built: PDFKit opening the placeholder would download it,
        // which nobody asked for.
        if isCloudOnly(path) {
            tools.banner = EditorPDFToolBanner(
                message: "“\((path as NSString).lastPathComponent)” is still in the cloud. Download it first.",
                kind: .note)
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
        guard case .facts(let pageCount, let encryption) = probe else {
            tools.banner = EditorPDFToolBanner(message: "PDFKit couldn’t read “\(name)”, so no tool can run on it.",
                                               kind: .failure)
            return
        }
        tools.attach(path: path, pageCount: pageCount, encryption: encryption)
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
        batch.showsSheet = true
        // Rotate asks nothing: the sheet opens on its progress.
        if case .rotate(let turns) = kind {
            work = Task { @MainActor in await batch.run(.rotate(quarterTurns: turns)) }
        }
    }
}

// MARK: - The window's half

/// **Where a pane-launched run shows itself**: its sheet over the window, and its banner at the
/// foot of the window — the same ``EditorPDFToolSheetView`` and the same banner row Edit's card
/// draws.
///
/// **A real `.sheet`, not an entry in the window's overlay chain.** The chain is a priority list
/// of full-window panels that yield to one another — Settings or Help opening covers whatever is
/// below it, and that one comes back when they close. A tool's sheet must not yield: its run is in
/// the lane, and its Cancel is the only way to stop it. A sheet is window-modal, so nothing can
/// cover it mid-run, and it is what Edit already presents these exact views in, so they look the
/// same from a pane as from Edit's Tools menu.
public struct PanePDFToolsPresenter: ViewModifier {
    let model: PanePDFTools
    let accent: Color

    public init(model: PanePDFTools, accent: Color) {
        self.model = model
        self.accent = accent
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            PanePDFToolsLayer(model: model, accent: accent)
        }
    }
}

/// Observes the window's model — the window itself does not, so a run's progress re-renders this
/// layer and nothing above it.
struct PanePDFToolsLayer: View {
    @ObservedObject var model: PanePDFTools
    let accent: Color

    var body: some View {
        switch model.current {
        case .single(let tools):
            PanePDFSingleLayer(tools: tools, accent: accent)
        case .batch(let batch):
            PanePDFBatchLayer(batch: batch, accent: accent)
        case nil:
            EmptyView()
        }
    }
}

struct PanePDFSingleLayer: View {
    @ObservedObject var tools: EditorPDFTools
    let accent: Color

    var body: some View {
        // A stack rather than a `Group`: with nothing to say a `Group` is no view at all, and the
        // sheet below would have nothing to hang from.
        VStack(spacing: 0) {
            // Edit's own banner — a run in flight with Cancel (Rotate opens no sheet), then the
            // run's word with Open and Reveal in Browse.
            if tools.banner != nil || (tools.running != nil && tools.sheet == nil) {
                PanePDFToolCard { EditorPDFToolBannerView(tools: tools, accent: accent) }
            }
        }
        .background {
            Color.clear.sheet(item: $tools.sheet) { sheet in
                EditorPDFToolSheetView(tools: tools, sheet: sheet, accent: accent)
            }
        }
    }
}

struct PanePDFBatchLayer: View {
    @ObservedObject var batch: EditorPDFBatch
    let accent: Color

    var body: some View {
        // A stack rather than a `Group`, for the sheet's sake — see ``PanePDFSingleLayer``.
        VStack(spacing: 0) {
            if batch.banner != nil {
                PanePDFToolCard { EditorPDFBatchBannerView(batch: batch, accent: accent) }
            }
        }
        .background {
            Color.clear.sheet(isPresented: $batch.showsSheet) {
                EditorPDFBatchSheet(batch: batch)
                    .padding(20)
                    .frame(width: 400)
                    .tint(accent)
            }
        }
    }
}

/// **A batch's ending**, in Edit's banner strip: the summary, Reveal in Browse over the copies it
/// wrote — and Open as well when there is just one.
struct EditorPDFBatchBannerView: View {
    @ObservedObject var batch: EditorPDFBatch
    let accent: Color

    var body: some View {
        if let banner = batch.banner {
            EditorPDFToolBannerView.strip(symbol: EditorPDFToolBannerView.symbol(banner.kind),
                                          tint: banner.kind == .failure ? .red : accent,
                                          message: banner.message) {
                switch banner.kind {
                case .wrote(let path):
                    Button("Open") { batch.host.open(path) }
                        .controlSize(.small)
                        .help("Open the copy in Edit")
                    Button("Reveal in Browse") { batch.host.reveal([path]) }
                        .controlSize(.small)
                        .help("Show the copy in Browse")
                case .wroteSeveral(let paths):
                    Button("Reveal in Browse") { batch.host.reveal(paths) }
                        .controlSize(.small)
                        .help("Show the copies in Browse")
                case .note, .failure:
                    EmptyView()
                }
                Button {
                    batch.banner = nil
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
    }
}

/// The banner's backing at the window's foot — Edit's row draws on the card's own surface; here it
/// floats over the panes, so it carries its own.
struct PanePDFToolCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.bottom, 44)
    }
}
