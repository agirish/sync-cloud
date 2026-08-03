import AppKit
import Design
import Events
import Quartz
import SwiftUI
import Sync
import UniformTypeIdentifiers

/// The file a Columns pane's preview column is showing, reduced to scalars.
///
/// Deliberately not a `PaneRow`/`FileNode`: a view that stores a node keeps that node's subtree
/// reachable from the view graph (the reason `FileRowInfo` exists at all), and a preview needs none
/// of it. `kind` comes from the node because `FileRowInfo` does not carry it.
struct ColumnPreviewItem: Equatable {
    let path: String
    let name: String
    /// The file's type, ready to read: "PDF document", not `com.adobe.pdf`.
    let kind: String?
    let fileSize: Int?
    let modified: Date?

    init(row: PaneRow) {
        self.path = row.node.id
        self.name = row.node.name
        self.kind = Self.describe(uti: row.node.kind)
        self.fileSize = row.node.fileSize
        self.modified = row.node.modificationDate
    }

    /// Turns the walk's raw type identifier into the description Finder shows.
    ///
    /// `FileNode.kind` holds `URLResourceValues.typeIdentifier` — a UTI — because that is what the
    /// Kind *sort* compares and what `kind:` search filters match; localizing it at the source would
    /// change both, and reorder every pane. So the translation happens here, at the one place a human
    /// reads it.
    ///
    /// An unrecognised type yields nothing rather than the raw identifier: `com.adobe.pdf` in a
    /// caption is worse than no caption, and a `dyn.…` placeholder says nothing at all.
    static func describe(uti: String?) -> String? {
        guard let uti, let type = UTType(uti), let description = type.localizedDescription
        else { return nil }
        return description
    }
}

/// Which file a preview column should show, given a pane's selection.
///
/// Pure and separate from the view because the answer is a rule, not a rendering: exactly one file,
/// selected in the deepest open column. Both halves matter.
///
/// - One item, because a preview names one file. A ⌘-click multi-selection has no single subject,
///   and previewing the "first" of it would describe a file the user did not point at.
/// - In the deepest column, because that is where a file selection lives by construction: clicking a
///   file truncates the stack to its own column (`PaneColumnsView.navigation(for:depth:)`), so a
///   selection resolved anywhere shallower is a stale one the pane has already navigated past.
enum ColumnPreview {
    static func item(selection: Set<String>, deepestRows: [PaneRow]) -> ColumnPreviewItem? {
        guard selection.count == 1, let id = selection.first,
              let row = deepestRows.first(where: { $0.id == id }),
              !row.node.isDirectory
        else { return nil }
        return ColumnPreviewItem(row: row)
    }
}

/// What the preview column can actually show for a path.
enum ColumnPreviewSource: Equatable, Sendable {
    /// Content is on disk — hand the path to Quick Look.
    case quickLook
    /// A cloud-only (dataless) placeholder. **Not** previewed: rendering it would force the provider
    /// to download the whole file, and this pane exists to browse cloud folders, where that is the
    /// normal case rather than the exception. Selecting a 4 GB video must not start a 4 GB transfer,
    /// so the column offers the download instead of performing it — the same rule
    /// `FileContentVerifier` already applies before reading a file's bytes.
    case cloudOnly
    /// The path is gone (a rescan hasn't caught up with a move or a delete yet).
    case missing

    /// Pure policy, given the two facts about the file. The dataless check comes first for the reason
    /// `FileContentVerifier` documents: a cloud-only placeholder is a placeholder whatever else is
    /// true of it.
    static func classify(exists: Bool, isCloudOnly: Bool) -> ColumnPreviewSource {
        if isCloudOnly { return .cloudOnly }
        return exists ? .quickLook : .missing
    }
}

/// What the preview area offers under the icon, for the file the column is showing.
///
/// A named value rather than a `ProgressView`/`Button` swap written inline in `body`, for exactly
/// the reason `ColumnPreviewColumn.paneToken` has no default: the user-visible half of
/// `isAwaitingDownload` was otherwise unprovable. Replacing the swap with `if false` — every
/// preview-started download losing its spinner and going on offering a Download button for a file
/// already downloading — left the whole suite green, because the only channel a test could read it
/// through does not exist. SwiftUI builds no accessibility tree at all without an assistive client
/// attached, so `accessibilityChildren()` on a hosted pane comes back empty under `swift test` and
/// any caption assertion passes vacuously; and whether SwiftUI's macOS `ProgressView` and `Button`
/// bridge to an `NSProgressIndicator`/`NSButton` a view walk could find is a version-dependent
/// implementation detail, not a contract worth resting a test on. Deciding it in a pure value moves
/// the decision somewhere a unit test can simply call.
enum PreviewAccessory: Equatable, Sendable {
    /// A spinner: the pane is watching a download of this file.
    case downloading
    /// The Download button, which asks the provider for the file's content.
    case offer
    /// Nothing below the caption.
    case none

    /// Pure policy, given the file's classification and whether the pane is watching a download of
    /// it. Only a `.cloudOnly` placeholder has anything to offer: a materialized file is previewed
    /// and a vanished one cannot be fetched, so neither takes a control.
    static func decide(source: ColumnPreviewSource?, isAwaitingDownload: Bool) -> PreviewAccessory {
        guard source == .cloudOnly else { return .none }
        return isAwaitingDownload ? .downloading : .offer
    }
}

/// One probe of a file: whether it can be previewed, plus the creation date, which `FileNode` does
/// not carry. Gathered together so the column pays one hop off the main actor, not two.
struct ColumnPreviewProbe: Equatable, Sendable {
    let source: ColumnPreviewSource
    let created: Date?

    /// Reads both facts. `nonisolated async`, so it runs on the cooperative pool rather than the
    /// caller's actor (SE-0338) — `lstat` and a resource-value read are cheap but they are still I/O,
    /// and this runs on every file click.
    ///
    /// `MaterializationStatus.isCloudOnly` is an `lstat`, which is metadata-only: it does not fetch
    /// the file. Nothing here opens the path.
    nonisolated static func read(path: String) async -> ColumnPreviewProbe {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        return ColumnPreviewProbe(
            source: .classify(exists: exists,
                              isCloudOnly: MaterializationStatus.isCloudOnly(atPath: path)),
            created: created)
    }
}

/// How a preview column probes the file it is showing.
///
/// A seam, not a policy — the default is the real `ColumnPreviewProbe.read`, unconditionally. It
/// exists because `.cloudOnly` is otherwise unreachable from a test, and `.cloudOnly` is the state
/// the entire download half of this column renders in: the Download button, the "Downloading…"
/// caption, and the re-probe when the pane's watch concludes. `SF_DATALESS` is an `SF_` *system*
/// flag — `chflags` refuses it to anyone but root, and in practice only a File Provider ever sets
/// it — so no fixture a test can build classifies as cloud-only, and that whole half shipped with
/// no mounted coverage at all.
///
/// Carried in the ENVIRONMENT rather than as an argument, because the wiring under test runs
/// through views the test cannot pass arguments to: `FileTreeView` owns the pane's watch,
/// `PaneColumnsView` hands it to this column, and a test has to mount the real pair to prove those
/// two hops are live. An environment value reaches through both without either having to know.
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

/// Finder's column-view preview, as this pane's rightmost column: the selected file rendered by
/// Quick Look, over the identity lines that say what it is.
///
/// Two things it deliberately does not do. It never previews a cloud-only placeholder (see
/// `ColumnPreviewSource.cloudOnly`), and it does not mount Quick Look the instant the selection
/// changes — `previewSettleDelay` passes first, so holding ↓ through a column of files walks the
/// selection without spawning a preview extension per row. The icon and the identity lines appear
/// immediately either way, so the column is never blank while it waits.
struct ColumnPreviewColumn: View {
    let item: ColumnPreviewItem
    /// Room held clear at the bottom for the pane's action bar, which overlays this column on a
    /// comparison pane. `0` where there is no bar — the Tidy rail. See the call site in
    /// `PaneColumnsView` for the measurement.
    var actionBarClearance: CGFloat = 0
    /// The pane this preview belongs to, so a download started HERE is watched by that pane — the
    /// same handshake a row-menu download uses (the notification is pane-scoped: see
    /// `CloudDownloadRequest`).
    ///
    /// **Required, with no default, deliberately.** It was `PaneToken? = nil`, and `requestDownload`
    /// downgraded the nil to "requested, unwatched" behind a debug log — so DELETING the argument at
    /// the one call site compiled, left the whole suite green, and cost every preview-started
    /// download its watch: no "Downloading…" caption, no badge clearing when the content landed.
    /// Nothing legitimately needs nil (the sole production caller is `PaneColumnsView`, which always
    /// knows its side), so the silent path is gone and the omission is a compile error instead.
    let paneToken: PaneToken
    /// Whether the pane is watching a download of the file this column is showing. Handed down by
    /// `PaneColumnsView` from the pane's `PaneDownloadWatch`: this column shows "Downloading…" while
    /// it is true, and re-probes when it goes false — the pane's watch concluding is what tells a
    /// materialized file it may be previewed.
    ///
    /// Read rather than run. This column used to keep its own `Task`, its own poll (twenty probes
    /// at 1.5 s) and its own `CloudOnlyBadgeCache.forget` for a download the pane's row was already
    /// polling — two watches and two forgets per download, and every forget invalidates every
    /// in-flight badge stat in BOTH panes. The pane is the single owner now (`PaneDownloadWatch`),
    /// and a pane-owned watch also covers the case this column made common: a download whose row is
    /// not realized at all.
    ///
    /// No default, for the reason `paneToken` has none: a `Bool` defaulting to `false` is an
    /// argument whose deletion compiles and silently disables the whole downloading state.
    let isAwaitingDownload: Bool

    /// Where this column ANNOUNCES a download, and it must be the same channel the pane that will
    /// watch it is listening on — see `PaneColumnsView.downloadChannel`, which supplies it.
    ///
    /// Defaulted, unlike the two properties above, because `.default` is a correct answer rather
    /// than a silently broken one: it is the channel the app runs on, and the only callers that
    /// pass anything else are tests isolating themselves from each other.
    var downloadChannel: NotificationCenter = .default

    /// The height the bar's band actually needs: its own height plus the padding the overlay adds
    /// around it. Only the BOTTOM edge is reserved. The bar flips to the top when the selected row is
    /// near its column's bottom, and there it covers the Quick Look area instead — an image that
    /// scales into whatever it is given, so it degrades where the identity rows could not. Reserving
    /// both edges would cost this column ~144pt to protect the half that tolerates the loss.
    ///
    /// This lands the identity block 16pt higher than it strictly needs to be, since the column's own
    /// `.padding(16)` already sits below it and the bar's *visible* top edge is 54pt up. The slack is
    /// deliberate: it keeps this number meaning exactly "the band the bar occupies", which is the
    /// thing `ColumnPreviewClearanceTests` can measure. Netting the padding off would couple the
    /// constant to a layout value in another expression for 16pt.
    ///
    /// A constant rather than a live read of `PaneBarPlacement.coverage`: writes to that class
    /// deliberately do not invalidate any view, so a body that read it would render from whatever the
    /// last layout pass happened to leave there. `ColumnPreviewClearanceTests` renders the real
    /// `PaneActionBar` and fails if it ever grows past this, which is what keeps the number honest.
    ///
    /// 72 rather than the 64 that bar measures here, and the 8pt is not padding-by-feel: the check is
    /// a `<=` against a height rendered on whatever machine runs it, and CI is x86-under-Rosetta while
    /// this was measured on arm64. At exactly 64 any cross-machine font-metric difference turns a
    /// green suite red for a reason that has nothing to do with the code under test. The headroom
    /// costs this column 8pt and buys the assertion room to be about the bar rather than the host.
    static let actionBarClearance: CGFloat = 72

    /// How long a file must stay selected before Quick Look is mounted for it.
    static let previewSettleDelay = Duration.milliseconds(180)

    /// One probe and the path it describes, as a SINGLE value.
    ///
    /// Folded together because the two are only ever meaningful as a pair, and the frame in which
    /// they disagreed was a real defect. `probe`/`hasSettled` used to be independent `@State`, reset
    /// at the top of `.task(id:)` — which runs *after* the body has already been committed with the
    /// NEW `item`. Walking from a settled local file to a cloud-only one therefore rendered one
    /// frame of `case .quickLook where hasSettled` for the new path, and that mounts
    /// `QLPreviewView` on it, which is the provider download `ColumnPreviewSource.cloudOnly` exists
    /// to prevent — "selecting a 4 GB video must not start a 4 GB transfer". The stale states were
    /// symmetric and all wrong: an old `.cloudOnly` offered a Download button captioned for the new
    /// file, an old `.missing` said "no longer here" about a file that is present.
    ///
    /// Carrying the path makes the reset synchronous instead: `probe` and `hasSettled` below read
    /// as "not probed yet" the instant `item` changes, in the same body evaluation, with no state
    /// written during it. A task cannot beat a render it runs after, so it must not be the thing
    /// that clears this.
    private struct ProbeResult: Equatable {
        let path: String
        let probe: ColumnPreviewProbe
        /// Whether `previewSettleDelay` has passed for `path`.
        var hasSettled: Bool
    }

    /// How to probe a path — the real `lstat` everywhere but in the tests that need `.cloudOnly`.
    /// See `ColumnPreviewProbeReader`.
    @Environment(\.columnPreviewProbe) private var probeReader

    /// The last probe to complete, whatever path it was for. Read through `probe`/`hasSettled`,
    /// never directly — a result for a path this column has moved off is not an answer about the
    /// file it is showing.
    @State private var probed: ProbeResult?
    /// Bumped to re-probe the same path — when the pane's download watch concludes.
    @State private var probeGeneration = 0

    /// The probe for the file on screen right now, or nil while one is in flight for it.
    private var probe: ColumnPreviewProbe? {
        guard let probed, probed.path == item.path else { return nil }
        return probed.probe
    }

    /// Whether `previewSettleDelay` has passed for the file on screen right now.
    private var hasSettled: Bool { probed?.path == item.path && probed?.hasSettled == true }

    /// Shared by the two date rows; `DateFormatter` is expensive to construct and `body` is not the
    /// place to do it (the same reason `DetailsSidebar` keeps one).
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// `.task(id:)` key: the path, plus the generation so a download request can re-run the probe
    /// for the very same file.
    private struct ProbeID: Equatable {
        let path: String
        let generation: Int
    }

    var body: some View {
        VStack(spacing: 14) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            identity
                .padding(.bottom, actionBarClearance)
        }
        .padding(16)
        // The content fills the column rather than capping at a "readable" width. The column's width
        // is now a deliberate choice — dragged from its divider and remembered — so capping the
        // content would mean widening the preview did nothing but add margins, which is precisely
        // what someone dragging it wider is asking not to happen. The metadata rows below spread
        // label-left / value-right, as Finder's do at any width.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No click catcher of its own, deliberately. The pane's deselect recognizers hang off each
        // column's own table view, so a click here cannot reach one — and a SwiftUI tap gesture
        // wrapped around a hosted `QLPreviewView` would compete with the preview's OWN controls
        // (a PDF's page arrows, a video's scrubber) for the same click.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(item.name)")
        // No reset at the top: this task runs after the body it would be resetting for has already
        // been committed. `ProbeResult` carries the path so the reset is the render's own, and this
        // task only ever writes results tagged with the path they describe.
        .task(id: ProbeID(path: item.path, generation: probeGeneration)) {
            let path = item.path
            let resolved = await probeReader.read(path)
            // `.task(id:)` cancels on a new id but the body still runs to its next suspension, so
            // every resumption re-checks: without this a fast walk down a column could commit an
            // earlier file's probe over a later one's.
            guard !Task.isCancelled else { return }
            // Settled-ness survives a RE-probe of the same path (the download the pane was watching
            // has concluded) and only that: for any other path `hasSettled` is already false. The
            // settle delay exists so holding ↓ through a column does not spawn a preview extension
            // per row, and a file the user explicitly asked to download is not that.
            probed = ProbeResult(path: path, probe: resolved, hasSettled: hasSettled)
            try? await Task.sleep(for: Self.previewSettleDelay)
            guard !Task.isCancelled, probed?.path == path else { return }
            probed?.hasSettled = true
        }
        // The pane's watch for the file on screen has ended (it landed, or the attempts ran out):
        // probe again so a file that materialized mounts its preview, and one that did not settles
        // back on the offer. Only the falling edge — arming the watch changes nothing on disk.
        //
        // Nothing to cancel when the selection moves on: this column owns no task now, and the pane
        // resolves this flag against the file the column is CURRENTLY showing, so it simply reads
        // false once the selection has moved off the downloading one.
        .onChange(of: isAwaitingDownload) { wasWatching, isWatching in
            if wasWatching, !isWatching { probeGeneration += 1 }
        }
    }

    // MARK: - What the preview area says and offers

    /// The line under the icon, for a classification and a download the pane may be watching.
    ///
    /// Pure and `static` so it can be called rather than rendered — see `PreviewAccessory` for why
    /// the rendered form is unreadable from a test. It takes the source rather than reading
    /// `probe?.source` so every case can be asked for directly, including the two nobody can stage:
    /// `.cloudOnly` needs the `SF_DATALESS` system flag, which only a File Provider ever sets.
    ///
    /// Nil for a file that is fine — a caption saying so would be noise under its own preview.
    static func caption(source: ColumnPreviewSource?, isAwaitingDownload: Bool) -> String? {
        switch source {
        case .cloudOnly: return isAwaitingDownload ? "Downloading…" : "Not downloaded"
        case .missing: return "This file is no longer here"
        // Both the pre-probe and pre-settle states, and the settled preview itself.
        case .quickLook, .none: return nil
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

    @ViewBuilder
    private var preview: some View {
        switch probe?.source {
        case .quickLook where hasSettled:
            QuickLookPreview(url: URL(fileURLWithPath: item.path))
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

    /// The control below the caption, rendered from `accessory` — the decision itself lives there.
    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .downloading:
            ProgressView().controlSize(.small)
        case .offer:
            Button("Download", action: requestDownload)
                .help("Fetch this file's content from the provider so it can be previewed")
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

    // MARK: - Identity

    @ViewBuilder
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .scaledFont(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.vertical, 2)
            if let created = probe?.created {
                metadataRow("Created", Self.dateFormatter.string(from: created))
            }
            if let modified = item.modified {
                metadataRow("Modified", Self.dateFormatter.string(from: modified))
            }
        }
    }

    /// "PDF document — 37 KB", with either half omitted when the walk didn't resolve it.
    private var subtitle: String? {
        let size = item.fileSize.map { FileSizeFormat.byteCount.string(fromByteCount: Int64($0)) }
        return [item.kind, size].compactMap { $0 }.joined(separator: " — ").nilIfEmpty
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(value)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Download

    /// Asks the provider for the file's content, then watches for it to arrive.
    ///
    /// Only iCloud exposes a consumer download API; for every other File Provider
    /// `MaterializationStatus.download` throws, and the honest fallback is Finder, which can reach
    /// the provider's own extension.
    private func requestDownload() {
        let path = item.path
        do {
            try MaterializationStatus.download(atPath: path)
            // Exactly the handshake the row menu's Download uses: hand the watch to the pane, which
            // forgets the memo's pre-download answer, polls once for the whole app, and drops its
            // latch when the content lands or the attempts run out. This column re-probes off that
            // latch (`isAwaitingDownload`) instead of running a second poll — two watches meant
            // two `forget`s, and each one invalidates every in-flight badge stat in both panes.
            CloudDownloadRequest.post(path: path, from: paneToken, through: downloadChannel)
        } catch {
            Logger.shared.warning("[preview] no download API for \(path): \(error.localizedDescription) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

/// `QLPreviewView` in SwiftUI — the same renderer Finder's preview column and the Quick Look panel
/// use, so PDFs page, images fit, text scrolls and video gets its controls without this app knowing
/// anything about those formats.
///
/// `autostarts` is off: a preview column fills as a side effect of clicking a row, and a video that
/// started playing because you selected it would be a sound the user did not ask for.
///
/// `close()` on dismantle is not optional housekeeping. Each live preview holds a Quick Look
/// extension process; a column that dropped its view without closing would leak one per file
/// previewed for as long as the app ran.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // `init(frame:style:)` is failable in the Objective-C header. A plain `QLPreviewView()` is
        // the documented fallback and gives the same `.normal` style.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        // Otherwise the view tears its preview down when the window closes and never rebuilds it,
        // which for a pane that outlives sheets and full-screen transitions reads as a dead column.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // Guarded: re-assigning the same item restarts the extension's render for nothing, and
        // `updateNSView` runs on every ancestor re-render — every scroll, every hover.
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
