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
    /// The pane this preview belongs to, so a download started HERE also puts the pane's row for
    /// the same file into the awaiting state (the notification is pane-scoped — see
    /// `CloudDownloadRequest`). `nil` for hosts with no pane around them (tests), which skips the
    /// post but never the cache `forget`.
    var paneToken: PaneToken? = nil

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
    /// Poll interval and ceiling for watching a started download materialize. Bounded rather than
    /// endless: if the provider never fetches the file, the column settles back on the offer.
    private static let downloadPollInterval = Duration.seconds(1.5)
    private static let downloadPollLimit = 20

    /// `nil` while the probe is in flight.
    @State private var probe: ColumnPreviewProbe?
    /// Set once `previewSettleDelay` has passed for the current path.
    @State private var hasSettled = false
    /// Bumped to re-probe the same path — after a download is requested.
    @State private var probeGeneration = 0
    /// The path the in-flight download watch is polling, nil when there is none. Live `@State`,
    /// which is the point: the old staleness guard compared the poll's `path` argument against a
    /// captured copy of `item` — two values frozen at the same instant, so the guard was a
    /// tautology and the watch outlived the selection it was started for. Reads of `@State`
    /// inside an escaping closure go through the live box, so THIS comparison can actually fail.
    @State private var watchedDownloadPath: String?
    /// The watch itself, kept so a selection change can cancel it instead of leaving a poll
    /// running against a file the column no longer shows.
    @State private var downloadWatchTask: Task<Void, Never>?

    /// Whether the "Downloading…" state applies to the file on screen right now.
    private var isWatchingDownload: Bool { watchedDownloadPath == item.path }

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
        .task(id: ProbeID(path: item.path, generation: probeGeneration)) {
            hasSettled = false
            let resolved = await ColumnPreviewProbe.read(path: item.path)
            // `.task(id:)` cancels on a new id but the body still runs to its next suspension, so
            // every resumption re-checks: without this a fast walk down a column could commit an
            // earlier file's probe over a later one's.
            guard !Task.isCancelled else { return }
            probe = resolved
            try? await Task.sleep(for: Self.previewSettleDelay)
            guard !Task.isCancelled else { return }
            hasSettled = true
        }
        // The selection moved on: the download watch (if any) is about a file this column no
        // longer shows, so it must actually STOP — not merely fall out of sync. The task handle
        // is cancelled rather than abandoned; the watcher also re-checks `watchedDownloadPath`
        // (live state) at every resumption, so whichever signal lands first ends it.
        .onChange(of: item.path) { _, _ in cancelDownloadWatch() }
        .onDisappear { cancelDownloadWatch() }
    }

    /// Tears down the in-flight download watch, if any.
    private func cancelDownloadWatch() {
        downloadWatchTask?.cancel()
        downloadWatchTask = nil
        watchedDownloadPath = nil
    }

    // MARK: - Preview area

    @ViewBuilder
    private var preview: some View {
        switch probe?.source {
        case .quickLook where hasSettled:
            QuickLookPreview(url: URL(fileURLWithPath: item.path))
        case .cloudOnly:
            placeholder(caption: isWatchingDownload ? "Downloading…" : "Not downloaded") {
                if isWatchingDownload {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download", action: requestDownload)
                        .help("Fetch this file's content from the provider so it can be previewed")
                }
            }
        case .missing:
            placeholder(caption: "This file is no longer here")
        // Both the pre-probe and pre-settle states: the icon, so the column has content the moment
        // it appears rather than a hole that fills in.
        case .quickLook, .none:
            placeholder()
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
            // Mirror the row-menu download path (`FileContextMenu`): drop the memo's pre-download
            // answer so the pane's row re-stats instead of reading "cloud-only" until the next
            // republish, and — when this preview knows its pane — put that row into the same
            // awaiting state a row-menu download would, so its badge clears as the content lands.
            CloudOnlyBadgeCache.forget(path)
            if let paneToken {
                NotificationCenter.default.post(
                    name: .cloudDownloadRequested,
                    object: CloudDownloadRequest(path: path, paneToken: paneToken))
            }
            cancelDownloadWatch()
            watchedDownloadPath = path
            downloadWatchTask = Task { await watchDownload(path: path) }
        } catch {
            Logger.shared.warning("[preview] no download API for \(path): \(error.localizedDescription) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Polls until the placeholder materializes, then re-probes so the preview mounts. Bounded,
    /// cancelled by `cancelDownloadWatch` when the selection moves on, and belt-and-braces checked
    /// against `watchedDownloadPath` — the LIVE box, not a captured copy — at every resumption.
    private func watchDownload(path: String) async {
        for _ in 0..<Self.downloadPollLimit {
            try? await Task.sleep(for: Self.downloadPollInterval)
            guard !Task.isCancelled, watchedDownloadPath == path else { return }
            if await ColumnPreviewProbe.read(path: path).source != .cloudOnly {
                guard !Task.isCancelled, watchedDownloadPath == path else { return }
                watchedDownloadPath = nil
                downloadWatchTask = nil
                probeGeneration += 1
                return
            }
        }
        guard watchedDownloadPath == path else { return }
        watchedDownloadPath = nil
        downloadWatchTask = nil
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
