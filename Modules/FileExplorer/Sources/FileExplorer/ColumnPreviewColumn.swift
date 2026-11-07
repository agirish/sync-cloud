import AppKit
import Design
import Events
import Quartz
import SwiftUI
import Sync
import UniformTypeIdentifiers

/// The file the preview is showing, reduced to scalars. Not a `PaneRow` or `FileNode`: a view that
/// stores a node keeps its subtree reachable from the view graph (why `FileRowInfo` exists), and a
/// preview needs none of it.
struct ColumnPreviewItem: Equatable {
    let path: String
    let name: String
    /// The file's type, which decides the renderer (see `PreviewRenderer`). From the walk's UTI when
    /// it has one, else the path's extension: `FileNode.kind` comes from a resource-value read that a
    /// deferred column listing can skip, and a PDF without its type would get the wrong renderer.
    let contentType: UTType?

    /// From the node: the Info inspector has a `FileNode` from the manager's path index, never a
    /// pane's projected row.
    init(node: FileNode) {
        self.path = node.id
        self.name = node.name
        self.contentType = Self.type(uti: node.kind, path: node.id)
    }

    /// The file's type, from the walk's identifier or, failing that, its extension.
    ///
    /// A dynamic identifier counts as no answer. `UTType("dyn.…")` succeeds, because the system
    /// mints a placeholder type for anything it doesn't recognise, so a plain `if let` would accept
    /// it and never reach the extension, the one thing that still knows the file is a PDF.
    static func type(uti: String?, path: String) -> UTType? {
        if let uti, let type = UTType(uti), !type.isDynamic { return type }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }
}

/// What the preview column can actually show for a path.
enum ColumnPreviewSource: Equatable, Sendable {
    /// Content is on disk: hand the path to Quick Look.
    case quickLook
    /// A cloud-only (dataless) placeholder. **Not** previewed: rendering it would make the provider
    /// download the whole file, and in a cloud folder that is the normal case. Selecting a 4 GB video
    /// must not start a 4 GB transfer, so the column offers the download instead, the same rule
    /// `FileContentVerifier` applies before reading a file's bytes.
    case cloudOnly
    /// The path is gone (a rescan hasn't caught up with a move or a delete yet).
    case missing

    /// Pure policy, given the two facts about the file. The dataless check comes first, as in
    /// `FileContentVerifier`: a cloud-only placeholder is a placeholder whatever else is true of it.
    static func classify(exists: Bool, isCloudOnly: Bool) -> ColumnPreviewSource {
        if isCloudOnly { return .cloudOnly }
        return exists ? .quickLook : .missing
    }
}

/// What the preview area offers under the icon, for the file the column is showing.
///
/// A named value rather than an inline `ProgressView`/`Button` swap in `body`, so a unit test can
/// call the decision. The rendered form can't be read from a test: SwiftUI builds no accessibility
/// tree without an assistive client, so `accessibilityChildren()` is empty under `swift test`, and
/// how `ProgressView` and `Button` bridge to AppKit views is a version-dependent detail.
enum PreviewAccessory: Equatable, Sendable {
    /// A spinner: the pane is watching a download of this file.
    case downloading
    /// The Download button, which asks the provider for the file's content.
    case offer
    /// Nothing below the caption.
    case none

    /// Pure policy, given the file's classification and whether the pane is watching a download of
    /// it. Only a `.cloudOnly` placeholder has anything to offer: a materialized file is previewed
    /// and a vanished one can't be fetched.
    static func decide(source: ColumnPreviewSource?, isAwaitingDownload: Bool) -> PreviewAccessory {
        guard source == .cloudOnly else { return .none }
        return isAwaitingDownload ? .downloading : .offer
    }
}

/// One probe of a file: whether it can be previewed.
struct ColumnPreviewProbe: Equatable, Sendable {
    let source: ColumnPreviewSource

    /// Reads it. `nonisolated async`, so it runs on the cooperative pool rather than the caller's
    /// actor (SE-0338): an existence check and an `lstat` are cheap, but still I/O on every click.
    ///
    /// `MaterializationStatus.isCloudOnly` is an `lstat`, metadata only, and nothing here opens the
    /// path, so nothing fetches the file. It is asked of the file a link points to: the link itself
    /// is always local, and Quick Look on it would fetch the file behind it.
    nonisolated static func read(path: String) async -> ColumnPreviewProbe {
        let exists = FileManager.default.fileExists(atPath: path)
        return ColumnPreviewProbe(
            source: .classify(exists: exists,
                              isCloudOnly: MaterializationStatus.isCloudOnly(
                                atPath: MaterializationStatus.linkTarget(of: path))))
    }
}

/// How a preview column probes the file it is showing.
///
/// A seam, not a policy: the default is always the real `ColumnPreviewProbe.read`. It exists
/// because no test fixture can be cloud-only (`SF_DATALESS` is a system flag that `chflags` refuses
/// to anyone but root; only a File Provider sets it), and `.cloudOnly` is where this column's whole
/// download half renders: the Download button, the "Downloading…" caption, and the re-probe.
///
/// Carried in the environment, because the test has to mount the real `InspectorFilePreview`, which
/// builds this column, beside the pane that watches its download; an environment value reaches
/// through without either knowing.
struct ColumnPreviewProbeReader: Sendable {
    let read: @Sendable (String) async -> ColumnPreviewProbe

    static let live = ColumnPreviewProbeReader { await ColumnPreviewProbe.read(path: $0) }
}

private struct ColumnPreviewProbeKey: EnvironmentKey {
    static let defaultValue = ColumnPreviewProbeReader.live
}

extension EnvironmentValues {
    var columnPreviewProbe: ColumnPreviewProbeReader {
        get { self[ColumnPreviewProbeKey.self] }
        set { self[ColumnPreviewProbeKey.self] = newValue }
    }
}

/// The selected file rendered by Quick Look or PDFKit, as the Info inspector draws it
/// (`InspectorFilePreview`). The name, kind and dates are the inspector's own details.
///
/// It never previews a cloud-only placeholder (see `ColumnPreviewSource.cloudOnly`), and it waits
/// `previewSettleDelay` before mounting Quick Look, so holding ↓ through a column doesn't spawn a
/// preview extension per row. The file's icon shows meanwhile, so the preview is never blank.
struct ColumnPreviewColumn: View {
    let item: ColumnPreviewItem
    /// The pane this preview belongs to, so a download started here is watched by that pane: the
    /// same handshake as a row-menu download (the notification is pane-scoped; see
    /// `CloudDownloadRequest`).
    ///
    /// Required, with no default, deliberately: if it were optional, dropping the argument would
    /// compile and silently cost every preview-started download its watch (no "Downloading…"
    /// caption, no badge clearing). The sole caller, `InspectorFilePreview`, always knows the pane.
    let paneToken: PaneToken
    /// Whether the pane is watching a download of the file this column is showing, as
    /// `InspectorFilePreview` follows the pane's `PaneDownloadWatch`: this column shows
    /// "Downloading…" while it is true, and re-probes when it goes false, since the watch ending is
    /// what tells a materialized file it may be previewed.
    ///
    /// Read, not run: the pane is the single owner of the watch. A second watch here would mean a
    /// second `CloudOnlyBadgeCache.forget` per download, and every forget invalidates every in-flight
    /// badge stat in both panes. A pane-owned watch also covers a download whose row isn't realized.
    ///
    /// No default, for `paneToken`'s reason: a `Bool` defaulting to `false` is an argument whose
    /// deletion compiles and silently disables the whole downloading state.
    let isAwaitingDownload: Bool

    /// Where this column announces a download. It must be the channel the watching pane listens on
    /// (see `FileTreeView.downloadChannel`).
    ///
    /// Defaulted, unlike the two above, because `.default` is a correct answer: it is the app's
    /// channel, and only tests isolating themselves pass anything else.
    var downloadChannel: NotificationCenter = .default

    /// How long a file must stay selected before Quick Look is mounted for it.
    static let previewSettleDelay = Duration.milliseconds(180)

    /// One probe and the path it describes, as a single value.
    ///
    /// **Never** split these into separate `@State` reset in `.task(id:)`: that task runs after the
    /// body is already committed with the new `item`, so for one frame a newly selected cloud-only
    /// file would read the old file's settled `.quickLook` and mount `QLPreviewView` on it, starting
    /// the very download `ColumnPreviewSource.cloudOnly` prevents. Stale states would also offer
    /// Download for the wrong file, or say a present file is "no longer here".
    ///
    /// Carrying the path makes the reset synchronous: `probe` and `hasSettled` read as "not probed
    /// yet" the instant `item` changes, in the same body evaluation, with no state written during it.
    private struct ProbeResult: Equatable {
        let path: String
        let probe: ColumnPreviewProbe
        /// Whether `previewSettleDelay` has passed for `path`.
        var hasSettled: Bool
    }

    /// How to probe a path: the real `lstat` everywhere but in the tests that need `.cloudOnly`.
    /// See `ColumnPreviewProbeReader`.
    @Environment(\.columnPreviewProbe) private var probeReader

    /// The last probe to complete, whatever path it was for. Read through `probe` and `hasSettled`,
    /// never directly: a result for a path this column has moved off says nothing about this file.
    @State private var probed: ProbeResult?
    /// Bumped to re-probe the same path, when the pane's download watch concludes.
    @State private var probeGeneration = 0

    /// The probe for the file on screen right now, or nil while one is in flight for it.
    private var probe: ColumnPreviewProbe? {
        guard let probed, probed.path == item.path else { return nil }
        return probed.probe
    }

    /// Whether `previewSettleDelay` has passed for the file on screen right now.
    private var hasSettled: Bool { probed?.path == item.path && probed?.hasSettled == true }

    /// `.task(id:)` key: the path, plus the generation so a download request can re-run the probe
    /// for the very same file.
    private struct ProbeID: Equatable {
        let path: String
        let generation: Int
    }

    var body: some View {
        preview
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            // The content fills the inspector rather than capping at a "readable" width: widening
            // the inspector should widen the picture, not add margins.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No click catcher of its own, deliberately. The pane's deselect recognizers hang off each
        // column's table view, so a click here can't reach one, and a SwiftUI tap gesture around a
        // hosted `QLPreviewView` would compete with the preview's own controls (a PDF's page
        // arrows, a video's scrubber).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(item.name)")
        // No reset at the top: this task runs after the body it would reset for is committed.
        // `ProbeResult` carries the path so the render does the reset, and this task only writes
        // results tagged with their path.
        .task(id: ProbeID(path: item.path, generation: probeGeneration)) {
            let path = item.path
            let resolved = await probeReader.read(path)
            // `.task(id:)` cancels on a new id, but the body runs on to its next suspension, so
            // re-check here, or a fast walk down a column could commit an earlier file's probe.
            guard !Task.isCancelled else { return }
            // Settledness survives only a re-probe of the same path (the pane's watched download
            // has concluded); for any other path `hasSettled` is already false. The settle delay is
            // for holding ↓ through a column, not for a file the user asked to download.
            probed = ProbeResult(path: path, probe: resolved, hasSettled: hasSettled)
            try? await Task.sleep(for: Self.previewSettleDelay)
            guard !Task.isCancelled, probed?.path == path else { return }
            probed?.hasSettled = true
        }
        // The pane's watch for the file on screen has ended (it landed, or the attempts ran out):
        // probe again so a materialized file mounts its preview and one that didn't settles back on
        // the offer. Only the falling edge, since arming the watch changes nothing on disk.
        //
        // Nothing to cancel when the selection moves: this column owns no task, and the pane
        // resolves this flag against the file currently shown, so it reads false once the
        // selection has moved off.
        .onChange(of: isAwaitingDownload) { wasWatching, isWatching in
            if wasWatching, !isWatching { probeGeneration += 1 }
        }
    }

    // MARK: - What the preview area says and offers

    /// The line under the icon, for a classification and a download the pane may be watching.
    ///
    /// Pure and `static` so it can be called rather than rendered (see `PreviewAccessory`). It takes
    /// the source rather than reading `probe?.source` so a test can ask for every case, including
    /// `.cloudOnly`, which needs a system flag only a File Provider sets.
    ///
    /// Nil for a file that is fine: a caption saying so would be noise under its own preview.
    static func caption(source: ColumnPreviewSource?, isAwaitingDownload: Bool) -> String? {
        switch source {
        case .cloudOnly: return isAwaitingDownload ? "Downloading…" : "Not downloaded"
        case .missing: return "This file is no longer here"
        // Both the pre-probe and pre-settle states, and the settled preview itself.
        case .quickLook, .none: return nil
        }
    }

    /// The line under the icon while a PDF preview has no page to show: none while it is still
    /// opening (the page is a moment away and a caption would flash), and the reason once it has
    /// failed. Pure and `static` for `caption(source:isAwaitingDownload:)`'s reason.
    static func pdfCaption(_ outcome: PDFOpenOutcome?) -> String? {
        switch outcome {
        case .unreadable: return "This PDF can’t be opened"
        case .locked: return "This PDF is password-protected"
        case .opened, .none: return nil
        }
    }

    /// `caption(source:isAwaitingDownload:)` for the file on screen right now.
    var previewCaption: String? {
        Self.caption(source: probe?.source, isAwaitingDownload: isAwaitingDownload)
    }

    /// `PreviewAccessory.decide(source:isAwaitingDownload:)` for the file on screen right now.
    var accessory: PreviewAccessory {
        PreviewAccessory.decide(source: probe?.source, isAwaitingDownload: isAwaitingDownload)
    }

    // MARK: - Preview area

    /// Which renderer draws this file once it has settled (see `PreviewRenderer`).
    var renderer: PreviewRenderer { PreviewRenderer.forType(item.contentType) }

    @ViewBuilder
    private var preview: some View {
        switch probe?.source {
        case .quickLook where hasSettled:
            // The settle delay applies to both renderers: holding ↓ through a folder of PDFs
            // shouldn't build a `PDFDocument` per row any more than a Quick Look extension.
            switch renderer {
            case .pdfPages:
                // The icon stays behind the page until it is parsed, and keeps a caption if it
                // never is (see `PDFPagePreview`).
                PDFPagePreview(url: URL(fileURLWithPath: item.path)) { outcome in
                    placeholder(caption: Self.pdfCaption(outcome))
                }
            case .quickLook:
                QuickLookPreview(url: URL(fileURLWithPath: item.path))
            }
        case .cloudOnly:
            placeholder(caption: previewCaption) { accessoryView }
        case .missing:
            placeholder(caption: previewCaption)
        // Both the pre-probe and pre-settle states: the icon, so the column has content the moment
        // it appears rather than a hole that fills in.
        case .quickLook, .none:
            placeholder()
        }
    }

    /// The control below the caption, rendered from `accessory`, where the decision lives.
    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .downloading:
            ProgressView().controlSize(.small)
        case .offer:
            Button("Download", action: requestDownload)
                .help("Fetch this file’s content from the provider so it can be previewed")
        case .none:
            EmptyView()
        }
    }

    /// The file-type icon at preview size, optionally captioned and with an action below it.
    @ViewBuilder
    private func placeholder<Accessory: View>(
        caption: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(spacing: 10) {
            Image(nsImage: FileIconCache.icon(name: item.name, isDirectory: false))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
            if let caption {
                Text(caption)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            accessory()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Download

    /// Asks the provider for the file's content, then lets the pane watch for it to arrive.
    ///
    /// The row menu's own verb, not a copy: the post hands the watch to the pane, which forgets the
    /// pre-download answer, polls once for the whole app, and drops its latch when the content lands
    /// or the attempts run out. This column re-probes off that latch (`isAwaitingDownload`) rather
    /// than polling itself. A refused request reveals the file in Finder.
    private func requestDownload() {
        CloudDownloadRequest.requestDownload(path: item.path, name: item.name, from: paneToken,
                                             through: downloadChannel)
    }
}

/// `QLPreviewView` in SwiftUI: the renderer Finder's preview column and the Quick Look panel use,
/// so PDFs page, images fit, text scrolls and video gets its controls without this app knowing the
/// formats.
///
/// `autostarts` is off: the preview fills as a side effect of selecting a row, and a video playing
/// because you selected it is a sound nobody asked for.
///
/// `close()` on dismantle is required. Each live preview holds a Quick Look extension process, and
/// a view dropped without closing leaks one per file previewed for as long as the app runs.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // `init(frame:style:)` is failable in the Objective-C header. A plain `QLPreviewView()` is
        // the documented fallback and gives the same `.normal` style.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        // Otherwise the view tears its preview down when the window closes and never rebuilds it,
        // so a pane that outlives sheets and full-screen transitions shows a dead column.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Guarded: re-assigning the same item restarts the extension's render for nothing, and
        // `updateNSView` runs on every ancestor re-render, every scroll and hover.
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
