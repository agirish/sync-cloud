import Testing
import Foundation
import Sync
import UniformTypeIdentifiers
@testable import FileExplorer

/// The rules behind the Info inspector's file preview: whether a file may be handed to Quick Look
/// at all, and what the preview area says when it isn't. Pure on purpose: the rendering can only
/// be judged by eye, but the policy (never a cloud-only placeholder) fails silently, looking like
/// a working preview while the provider downloads gigabytes nobody asked for.
@Suite struct ColumnPreviewTests {

    private static let dir = "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Documents/TODO"

    // MARK: - Whether Quick Look may see it

    /// Every case of the classification. The one that matters is a cloud-only placeholder: in
    /// cloud folders a dataless placeholder is a file's normal state, and handing one to Quick Look
    /// makes the provider fetch it all, so selecting a row must never do that. The dataless check
    /// comes first, as `FileContentVerifier` explains: a placeholder is a placeholder whatever else
    /// is true of it. A path a rescan hasn't caught up with is distinguished from a placeholder:
    /// one offers a download, the other says the file is gone, and collapsing them would offer to
    /// download a file that no longer exists.
    @Test(arguments: [
        (true, true, ColumnPreviewSource.cloudOnly),     // never handed to Quick Look
        (false, true, ColumnPreviewSource.cloudOnly),    // dataless outranks everything else
        (true, false, ColumnPreviewSource.quickLook),    // a materialized file is previewable
        (false, false, ColumnPreviewSource.missing),     // vanished, not cloud-only
    ])
    func testClassify(exists: Bool, isCloudOnly: Bool, expected: ColumnPreviewSource) {
        #expect(ColumnPreviewSource.classify(exists: exists, isCloudOnly: isCloudOnly) == expected)
    }

    // MARK: - What the preview area says and offers

    /// What the area says and offers, as values because SwiftUI builds no accessibility tree
    /// without an assistive client. A download in flight shows its spinner, not a Download button;
    /// an idle placeholder offers the fetch; a vanished file can't be fetched (`testClassify`'s
    /// vanished-file rule, at the control); a materialized or unprobed file is bare, the icon
    /// alone. `isAwaitingDownload` is read only through the classification: a watch reaching a
    /// column that moved on to a local file must not caption it "Downloading…".
    @Test(arguments: [
        (ColumnPreviewSource?.some(.cloudOnly), true, "Downloading…", PreviewAccessory.downloading),
        (.cloudOnly, false, "Not downloaded", .offer),
        (.missing, false, "This file is no longer here", .none),
        (.missing, true, "This file is no longer here", .none),
        (.quickLook, false, nil, .none),
        (.quickLook, true, nil, .none),
        (nil, false, nil, .none),
        (nil, true, nil, .none),
    ] as [(ColumnPreviewSource?, Bool, String?, PreviewAccessory)])
    func theAreaSaysAndOffers(source: ColumnPreviewSource?, isAwaitingDownload: Bool,
                              caption: String?, accessory: PreviewAccessory) {
        #expect(ColumnPreviewColumn.caption(source: source, isAwaitingDownload: isAwaitingDownload)
                == caption)
        #expect(PreviewAccessory.decide(source: source, isAwaitingDownload: isAwaitingDownload)
                == accessory)
    }

    /// Before its own probe completes the column offers nothing, whatever the pane's latch says.
    /// Ties the two instance properties to the statics above: forward either to a constant and this
    /// fails.
    @MainActor
    @Test func anUnprobedColumnOffersNothing() {
        let item = ColumnPreviewItem(node: FileNode(
            id: "\(Self.dir)/scan.pdf", name: "scan.pdf", isDirectory: false,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            fileSize: 37_000, kind: "com.adobe.pdf"))
        let column = ColumnPreviewColumn(item: item, paneToken: .left, isAwaitingDownload: true)

        #expect(column.accessory == .none)
        #expect(column.previewCaption == nil)
    }

    /// The real probe, over a real file, against a real (non-dataless) temp directory: the wiring
    /// from `classify` to the two syscalls, which the pure tests above cannot see.
    @Test func testTheProbeReadsARealFile() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ColumnPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)

        let present = await ColumnPreviewProbe.read(path: file.path)
        #expect(present.source == .quickLook)

        let absent = await ColumnPreviewProbe.read(path: dir.appendingPathComponent("gone.txt").path)
        #expect(absent.source == .missing)
    }
}
