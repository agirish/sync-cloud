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

    private static func rows() -> [PaneRow] {
        let nodes = [
            FileNode(id: "\(dir)/School", name: "School", isDirectory: true, children: []),
            FileNode(id: "\(dir)/scan.pdf", name: "scan.pdf", isDirectory: false,
                     modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                     fileSize: 37_000, kind: "com.adobe.pdf"),
            FileNode(id: "\(dir)/notes.txt", name: "notes.txt", isDirectory: false),
        ]
        return PaneRow.project(nodes, side: .left, version: 1)
    }

    /// The item for one of `rows()`'s files.
    private static func item(_ name: String) throws -> ColumnPreviewItem {
        ColumnPreviewItem(node: try #require(rows().first { $0.id == "\(dir)/\(name)" }?.node))
    }

    // MARK: - Whether Quick Look may see it

    /// The case that matters. In cloud folders a dataless placeholder is a file's normal state, and
    /// handing one to Quick Look makes the provider fetch it all. Selecting a row must never do that.
    @Test func testACloudOnlyPlaceholderIsNeverHandedToQuickLook() {
        #expect(ColumnPreviewSource.classify(exists: true, isCloudOnly: true) == .cloudOnly)
    }

    /// The dataless check comes first, as `FileContentVerifier` explains: a placeholder is a
    /// placeholder whatever else is true of it.
    @Test func testTheDatalessCheckOutranksEverythingElse() {
        #expect(ColumnPreviewSource.classify(exists: false, isCloudOnly: true) == .cloudOnly)
    }

    @Test func testAMaterializedFileIsPreviewable() {
        #expect(ColumnPreviewSource.classify(exists: true, isCloudOnly: false) == .quickLook)
    }

    /// A path a rescan hasn't caught up with is distinguished from a placeholder: one offers a
    /// download, the other says the file is gone. Collapsing them would offer to download a file
    /// that no longer exists.
    @Test func testAVanishedFileIsMissingRatherThanCloudOnly() {
        #expect(ColumnPreviewSource.classify(exists: false, isCloudOnly: false) == .missing)
    }

    // MARK: - What the preview area says and offers

    /// The user-visible half of `isAwaitingDownload`: a download in flight shows its spinner, not a
    /// Download button. Tested as values because the rendered form can't be read: SwiftUI builds no
    /// accessibility tree without an assistive client. Fails if the caption becomes a constant
    /// `"Not downloaded"` or the control swap `if false`.
    @Test func aDownloadInFlightSaysSoAndShowsProgressInsteadOfTheOffer() {
        #expect(ColumnPreviewColumn.caption(source: .cloudOnly, isAwaitingDownload: true)
                == "Downloading…")
        #expect(PreviewAccessory.decide(source: .cloudOnly, isAwaitingDownload: true) == .downloading)
    }

    /// The resting state of a placeholder: say it is not here, and offer to fetch it.
    @Test func anIdlePlaceholderOffersTheDownload() {
        #expect(ColumnPreviewColumn.caption(source: .cloudOnly, isAwaitingDownload: false)
                == "Not downloaded")
        #expect(PreviewAccessory.decide(source: .cloudOnly, isAwaitingDownload: false) == .offer)
    }

    /// Only a placeholder has anything to offer. A vanished file can't be fetched; this is
    /// `testAVanishedFileIsMissingRatherThanCloudOnly`'s rule, at the control.
    @Test func aVanishedFileSaysSoAndOffersNothing() {
        #expect(ColumnPreviewColumn.caption(source: .missing, isAwaitingDownload: false)
                == "This file is no longer here")
        #expect(PreviewAccessory.decide(source: .missing, isAwaitingDownload: false) == .none)
    }

    /// A materialized or not-yet-probed file is captionless and bare, the icon alone, so the column
    /// has content the moment it appears.
    @Test func aPreviewableOrUnprobedFileIsBare() {
        for source: ColumnPreviewSource? in [.quickLook, nil] {
            #expect(ColumnPreviewColumn.caption(source: source, isAwaitingDownload: false) == nil)
            #expect(PreviewAccessory.decide(source: source, isAwaitingDownload: false) == .none)
        }
    }

    /// `isAwaitingDownload` is read only through the classification. The probe for the shown file can
    /// still be out, and a watch reaching a column that moved on to a local file must not caption it
    /// "Downloading…" or hide its preview behind a spinner.
    @Test func aWatchOnAFileThatIsNotAPlaceholderChangesNothing() {
        for source: ColumnPreviewSource? in [.quickLook, .missing, nil] {
            #expect(ColumnPreviewColumn.caption(source: source, isAwaitingDownload: true)
                    == ColumnPreviewColumn.caption(source: source, isAwaitingDownload: false))
            #expect(PreviewAccessory.decide(source: source, isAwaitingDownload: true) == .none)
        }
    }

    /// Before its own probe completes the column offers nothing, whatever the pane's latch says.
    /// Ties the two instance properties to the statics above: forward either to a constant and this
    /// fails.
    @MainActor
    @Test func anUnprobedColumnOffersNothing() throws {
        let item = try Self.item("scan.pdf")
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
