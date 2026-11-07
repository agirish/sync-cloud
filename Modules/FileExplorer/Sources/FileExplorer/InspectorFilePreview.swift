import SwiftUI
import Sync

/// The file preview as the window's Info inspector draws it: the picture alone, over the
/// inspector's own details, which list the name, kind and dates.
///
/// Its downloads live in the host's `InspectorDownloads`, not in `@State`: the preview is taken down
/// whenever the inspector shows something else, and a "Downloading…" kept here would die with it,
/// so back on the file the inspector would offer Download again mid-fetch.
///
/// Rebuilt (a fresh probe and renderer) when the file changes on disk and when a watch of it ends,
/// so a saved or signed file and a landed download show what is on disk now. Quick Look and PDFKit
/// keep what they first read for a URL they already have.
public struct InspectorFilePreview: View {
    let item: ColumnPreviewItem
    let modified: Date?
    let paneToken: PaneToken
    let paneWatches: Bool
    let downloadChannel: NotificationCenter
    @ObservedObject var downloads: InspectorDownloads

    /// - Parameters:
    ///   - paneToken: the pane the file was selected in, which a Download started here is posted from.
    ///   - paneWatches: whether that pane is on screen to watch the download. When it is not — Edit
    ///     with its file pane folded, a Get Info target from a pane that is hidden — `downloads` runs
    ///     the watch itself, so the file still arrives and the badge still clears.
    public init(node: FileNode, paneToken: PaneToken, paneWatches: Bool, downloads: InspectorDownloads,
                downloadChannel: NotificationCenter = .default) {
        self.item = ColumnPreviewItem(node: node)
        self.modified = node.modificationDate
        self.paneToken = paneToken
        self.paneWatches = paneWatches
        self.downloads = downloads
        self.downloadChannel = downloadChannel
    }

    /// What a fresh column is keyed on: the file, its content's date, and how many watches of it
    /// have ended.
    struct Identity: Hashable {
        let path: String
        let modified: Date?
        let watchesEnded: Int
    }

    public var body: some View {
        ColumnPreviewColumn(item: item, paneToken: paneToken,
                            isAwaitingDownload: downloads.isAwaiting(item.path),
                            downloadChannel: downloadChannel)
            .id(Identity(path: item.path, modified: modified, watchesEnded: downloads.watchesEnded(item.path)))
            .onReceive(downloadChannel.publisher(for: .cloudDownloadRequested)) { note in
                guard !paneWatches,
                      let request = CloudDownloadRequest.accepted(from: note, paneToken: paneToken),
                      request.path == item.path else { return }
                downloads.watchUnheard(request)
            }
    }
}

/// The Info inspector's downloads, kept by the host so they outlive the preview.
///
/// Follows every download request on its channel to the end of its watch: "Downloading…" from the
/// request, cleared by the `.cloudDownloadWatchEnded` the watching pane posts, matched by
/// `requestID`, never path, so a repeat Download's old watch can't clear the new one. Each ended
/// watch counts against its file and the preview rebuilds on the count, so a file that lands after
/// `unheardDeadline` is still looked at again.
///
/// One watch per download: the pane that posted the request runs it. Only a request whose pane
/// isn't on screen is watched here (`watchUnheard`), with the same watch and channel.
@MainActor
public final class InspectorDownloads: ObservableObject {
    @Published private var awaiting: [String: CloudDownloadRequest] = [:]
    @Published private var ended: [String: Int] = [:]
    private let channel: NotificationCenter
    private let deadline: Duration
    private let watch: PaneDownloadWatch
    private var deadlines: [String: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// How long "Downloading…" waits for a watch that never says it ended: a whole watch and one
    /// interval more. Reached only when the watching pane is taken down mid-watch. A backstop that
    /// polls nothing; it counts as an ending, so the file is looked at again.
    nonisolated public static let unheardDeadline = CloudDownloadPoll.interval * (CloudDownloadPoll.attempts + 1)

    /// - Parameters:
    ///   - channel: where requests and the ends of watches are posted — `.default` in the app.
    ///   - deadline: `unheardDeadline` in the app; a test puts it out of reach.
    public convenience init(channel: NotificationCenter = .default,
                            deadline: Duration = InspectorDownloads.unheardDeadline) {
        self.init(channel: channel, deadline: deadline, watch: PaneDownloadWatch())
    }

    init(channel: NotificationCenter, deadline: Duration, watch: PaneDownloadWatch) {
        self.channel = channel
        self.deadline = deadline
        self.watch = watch
        // `queue: nil` delivers on the posting thread, which is the main actor for every poster:
        // the verb and the watch are both `@MainActor`.
        observers.append(channel.addObserver(forName: .cloudDownloadRequested, object: nil, queue: nil) {
            [weak self] note in
            guard let request = note.object as? CloudDownloadRequest else { return }
            MainActor.assumeIsolated { self?.requested(request) }
        })
        observers.append(channel.addObserver(forName: .cloudDownloadWatchEnded, object: nil, queue: nil) {
            [weak self] note in
            guard let request = note.object as? CloudDownloadRequest else { return }
            MainActor.assumeIsolated { self?.watchEnded(request) }
        })
    }

    deinit {
        for observer in observers { channel.removeObserver(observer) }
    }

    /// Whether a download of `path` is being waited on.
    public func isAwaiting(_ path: String) -> Bool { awaiting[path] != nil }

    /// How many watches of `path` have ended, or been given up on.
    public func watchesEnded(_ path: String) -> Int { ended[path] ?? 0 }

    func requested(_ request: CloudDownloadRequest) {
        awaiting[request.path] = request
        deadlines[request.path]?.cancel()
        let deadline = self.deadline
        deadlines[request.path] = Task { [weak self] in
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            self?.gaveUp(on: request)
        }
    }

    /// Watches `request` here, because no pane on screen will. Idempotent per request.
    func watchUnheard(_ request: CloudDownloadRequest) {
        if awaiting[request.path]?.requestID != request.requestID { requested(request) }
        guard watch.request(forPath: request.path)?.requestID != request.requestID else { return }
        watch.begin(request, announcingOn: channel)
    }

    func watchEnded(_ request: CloudDownloadRequest) {
        if awaiting[request.path]?.requestID == request.requestID {
            awaiting[request.path] = nil
            deadlines[request.path]?.cancel()
            deadlines[request.path] = nil
        }
        ended[request.path, default: 0] += 1
    }

    private func gaveUp(on request: CloudDownloadRequest) {
        guard awaiting[request.path]?.requestID == request.requestID else { return }
        awaiting[request.path] = nil
        deadlines[request.path] = nil
        ended[request.path, default: 0] += 1
    }
}
