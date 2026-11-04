import Testing
import Foundation
import Sync
import UniformTypeIdentifiers
@testable import FileExplorer

/// The rules behind the file preview (the Info inspector's, since TE317 C): *whether* a file may be
/// handed to Quick Look at all, and what the preview area says when it is not.
///
/// Pure on purpose. The rendering is a `QLPreviewView` and can only be judged by eye, but the
/// policy — never a cloud-only placeholder — is exactly the part that would fail silently:
/// previewing a dataless placeholder looks like a working preview, right up until the provider has
/// downloaded four gigabytes nobody asked for.
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

    /// The load-bearing case. This pane browses cloud folders, where a dataless placeholder is the
    /// normal state of a file rather than an edge case, and handing one to Quick Look forces the
    /// provider to fetch the whole thing. Selecting a row must never do that.
    @Test func testACloudOnlyPlaceholderIsNeverHandedToQuickLook() {
        #expect(ColumnPreviewSource.classify(exists: true, isCloudOnly: true) == .cloudOnly)
    }

    /// The dataless check comes FIRST, for the reason `FileContentVerifier` documents: a placeholder
    /// is a placeholder whatever else is true of it. An ordering that tested existence first would
    /// classify the (common) present-but-dataless file as previewable.
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

    /// The user-visible half of `isAwaitingDownload`, which shipped unproven.
    ///
    /// Mutating the caption to a constant `"Not downloaded"` and the control swap to `if false` —
    /// every preview-started download losing its spinner and going on offering a Download button
    /// for a file already downloading — left all 677 tests green. The rendered form has no channel:
    /// SwiftUI builds no accessibility tree without an assistive client, so a caption assertion on a
    /// hosted pane passes vacuously, and whether `ProgressView`/`Button` bridge to findable AppKit
    /// views is a version-dependent detail. The decision is a value now, so these are calls.
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

    /// Only a placeholder has anything to offer. A vanished file cannot be fetched — offering a
    /// Download button for it is the collapse `testAVanishedFileIsMissingRatherThanCloudOnly`
    /// prevents one step earlier, arriving at the control instead of at the classification.
    @Test func aVanishedFileSaysSoAndOffersNothing() {
        #expect(ColumnPreviewColumn.caption(source: .missing, isAwaitingDownload: false)
                == "This file is no longer here")
        #expect(PreviewAccessory.decide(source: .missing, isAwaitingDownload: false) == .none)
    }

    /// And a materialized or not-yet-probed file is captionless and bare — the icon alone, so the
    /// column has content the moment it appears.
    @Test func aPreviewableOrUnprobedFileIsBare() {
        for source: ColumnPreviewSource? in [.quickLook, nil] {
            #expect(ColumnPreviewColumn.caption(source: source, isAwaitingDownload: false) == nil)
            #expect(PreviewAccessory.decide(source: source, isAwaitingDownload: false) == .none)
        }
    }

    /// `isAwaitingDownload` may only be read THROUGH the classification. The pane resolves the flag
    /// against the file the column is currently showing, but the probe for that file can still be
    /// out — and a watch reaching a column that has already moved on to a local file must not
    /// caption it "Downloading…" or hide its preview behind a spinner.
    @Test func aWatchOnAFileThatIsNotAPlaceholderChangesNothing() {
        for source: ColumnPreviewSource? in [.quickLook, .missing, nil] {
            #expect(ColumnPreviewColumn.caption(source: source, isAwaitingDownload: true)
                    == ColumnPreviewColumn.caption(source: source, isAwaitingDownload: false))
            #expect(PreviewAccessory.decide(source: source, isAwaitingDownload: true) == .none)
        }
    }

    /// The column reads its own probe: before one completes there is nothing to offer, whatever the
    /// pane's latch says. Pins the two instance properties onto the statics above — mutate either
    /// forward to a constant and this fails.
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
