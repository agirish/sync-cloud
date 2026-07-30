import AppKit
import Design
import Events
import Quartz
import SwiftUI
import Sync

/// The file a Columns pane's preview column is showing, reduced to scalars.
///
/// Deliberately not a `PaneRow`/`FileNode`: a view that stores a node keeps that node's subtree
/// reachable from the view graph (the reason `FileRowInfo` exists at all), and a preview needs none
/// of it. `kind` comes from the node because `FileRowInfo` does not carry it.
struct ColumnPreviewItem: Equatable {
    let path: String
    let name: String
    /// The system's human-readable type ("PDF document"), when the walk resolved one.
    let kind: String?
    let fileSize: Int?
    let modified: Date?

    init(row: PaneRow) {
        self.path = row.node.id
        self.name = row.node.name
        self.kind = row.node.kind
        self.fileSize = row.node.fileSize
        self.modified = row.node.modificationDate
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
    /// The sentinel `ScrollViewReader` id for the preview column. Prefixed with NUL, which cannot
    /// occur in a POSIX path, so it can never collide with a column's own directory id.
    static let scrollID = "\u{0}columnPreview"

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
    @State private var isWatchingDownload = false

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
        }
        .padding(16)
        // The column takes every point the list columns leave (as Finder's does), but its CONTENT
        // stops widening: a name and four metadata rows stretched across 700pt read as a form, not
        // as a caption under a preview.
        .frame(maxWidth: 460)
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
            isWatchingDownload = true
            Task { await watchDownload(path: path) }
        } catch {
            Logger.shared.warning("[preview] no download API for \(path): \(error.localizedDescription) — revealing in Finder")
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    /// Polls until the placeholder materializes, then re-probes so the preview mounts. Bounded, and
    /// abandoned outright if the selection has moved on to another file.
    private func watchDownload(path: String) async {
        for _ in 0..<Self.downloadPollLimit {
            try? await Task.sleep(for: Self.downloadPollInterval)
            guard item.path == path else { return }
            if await ColumnPreviewProbe.read(path: path).source != .cloudOnly {
                isWatchingDownload = false
                probeGeneration += 1
                return
            }
        }
        isWatchingDownload = false
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
