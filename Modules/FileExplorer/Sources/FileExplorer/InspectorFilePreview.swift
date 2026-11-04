import SwiftUI
import Sync

/// The file preview as the window's Info inspector draws it (TE317 C): the same renderer as the
/// pane's preview column, without the name and dates the inspector's own details already list.
///
/// It watches its own downloads, as Compare Copies does (`PaneDownloadWatch`): the pane that owns
/// the file watches too, through the token the request names, so the row's badge clears as it
/// always did, and this view re-probes when the content lands.
public struct InspectorFilePreview: View {
    let item: ColumnPreviewItem
    let paneToken: PaneToken
    let downloadChannel: NotificationCenter
    let onOpenInEditor: (String) -> Void

    @StateObject private var downloads = PaneDownloadWatch()

    /// - Parameter paneToken: the pane the file was selected in, so a Download started here is
    ///   watched by that pane as well.
    public init(node: FileNode, paneToken: PaneToken, downloadChannel: NotificationCenter = .default,
                onOpenInEditor: @escaping (String) -> Void) {
        self.item = ColumnPreviewItem(node: node)
        self.paneToken = paneToken
        self.downloadChannel = downloadChannel
        self.onOpenInEditor = onOpenInEditor
    }

    public var body: some View {
        ColumnPreviewColumn(item: item, paneToken: paneToken,
                            isAwaitingDownload: downloads.requests[item.path] != nil,
                            downloadChannel: downloadChannel, onOpenInEditor: onOpenInEditor,
                            showsIdentity: false)
            // A fresh column per file, so a probe or a settle delay never carries over.
            .id(item.path)
            .onReceive(downloadChannel.publisher(for: .cloudDownloadRequested)) { note in
                if let request = CloudDownloadRequest.accepted(from: note, paneToken: paneToken),
                   request.path == item.path {
                    downloads.begin(request)
                }
            }
    }
}
