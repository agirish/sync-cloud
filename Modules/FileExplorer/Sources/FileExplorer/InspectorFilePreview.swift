import SwiftUI
import Sync

/// The file preview as the window's Info inspector draws it (TE317 C): the picture alone, over the
/// inspector's own details, which list the name, kind and dates.
///
/// **It watches no download of its own.** The pane the file was selected in does: a Download here
/// posts through that pane's token, the pane runs the one watch (one poll, one memo `forget`) and
/// clears the row's badge as it always did, and this view only follows it — "Downloading…" from the
/// request it hears to the `.cloudDownloadWatchEnded` the pane posts, then a re-probe. It used to
/// run a second watch beside the pane's, which doubled both.
public struct InspectorFilePreview: View {
    let item: ColumnPreviewItem
    let paneToken: PaneToken
    let downloadChannel: NotificationCenter

    /// The pane's download of the file on screen, from its request until the pane says its watch
    /// ended — or until `unheardDeadline`, for a request no pane picked up.
    @State private var awaiting: CloudDownloadRequest?
    /// `unheardDeadline` in the app — see `inspectorDownloadDeadline`.
    @Environment(\.inspectorDownloadDeadline) private var deadline

    /// How long "Downloading…" waits for a pane that never says it is done: a whole watch and one
    /// interval more. Only reached when no mounted pane carries `paneToken` — a Get Info target found
    /// in a tree whose pane is not on screen — since a pane that heard the request always ends its
    /// watch within `attempts × interval`. A deadline, not a watch: it polls nothing.
    nonisolated static let unheardDeadline = CloudDownloadPoll.interval * (CloudDownloadPoll.attempts + 1)

    /// - Parameter paneToken: the pane the file was selected in, which watches a Download started
    ///   here.
    public init(node: FileNode, paneToken: PaneToken, downloadChannel: NotificationCenter = .default) {
        self.item = ColumnPreviewItem(node: node)
        self.paneToken = paneToken
        self.downloadChannel = downloadChannel
    }

    public var body: some View {
        ColumnPreviewColumn(item: item, paneToken: paneToken,
                            isAwaitingDownload: awaiting?.path == item.path,
                            downloadChannel: downloadChannel)
            // A fresh column per file, so a probe or a settle delay never carries over.
            .id(item.path)
            .onReceive(downloadChannel.publisher(for: .cloudDownloadRequested)) { note in
                awaiting = Self.awaiting(after: note, current: awaiting, path: item.path, paneToken: paneToken)
            }
            .onReceive(downloadChannel.publisher(for: .cloudDownloadWatchEnded)) { note in
                awaiting = Self.awaiting(after: note, current: awaiting, path: item.path, paneToken: paneToken)
            }
            .task(id: awaiting?.requestID) {
                guard let waiting = awaiting,
                      (try? await Task.sleep(for: deadline)) != nil,
                      awaiting?.requestID == waiting.requestID else { return }
                awaiting = nil
            }
    }

    /// What `awaiting` becomes after `note`: a request from this view's pane for the file on screen
    /// starts it, the end of the watch for exactly that request clears it, and anything else leaves
    /// it as it was. By `requestID`, never path — the rule `CloudDownloadRequest.concludes` states:
    /// a repeat Download of the same file supersedes the old request, and the old watch's end must
    /// not clear the new one.
    static func awaiting(after note: Notification, current: CloudDownloadRequest?, path: String,
                         paneToken: PaneToken) -> CloudDownloadRequest? {
        switch note.name {
        case .cloudDownloadRequested:
            guard let request = CloudDownloadRequest.accepted(from: note, paneToken: paneToken),
                  request.path == path else { return current }
            return request
        case .cloudDownloadWatchEnded:
            guard let ended = note.object as? CloudDownloadRequest,
                  ended.requestID == current?.requestID else { return current }
            return nil
        default:
            return current
        }
    }
}

private struct InspectorDownloadDeadlineKey: EnvironmentKey {
    static let defaultValue = InspectorFilePreview.unheardDeadline
}

extension EnvironmentValues {
    /// How long the inspector's "Downloading…" waits for a pane that never says its watch ended.
    /// `InspectorFilePreview.unheardDeadline` everywhere but the one test that has to tell the
    /// pane's word from the deadline: it puts the deadline out of reach, so a re-probe can only be
    /// the pane's. A wall-clock bound cannot tell them apart on a loaded machine.
    var inspectorDownloadDeadline: Duration {
        get { self[InspectorDownloadDeadlineKey.self] }
        set { self[InspectorDownloadDeadlineKey.self] = newValue }
    }
}
