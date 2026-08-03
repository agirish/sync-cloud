import Testing
import Foundation
import Sync
import UniformTypeIdentifiers
@testable import FileExplorer

/// The two rules behind the Columns preview column: *which* file it shows, and *whether* that file
/// may be handed to Quick Look at all.
///
/// Both are pure on purpose. The rendering is a `QLPreviewView` and can only be judged by eye, but
/// the policy — one file, the deepest column, never a cloud-only placeholder — is exactly the part
/// that would fail silently: previewing the wrong file still *looks* like a working preview, and
/// previewing a dataless placeholder looks like one too, right up until the provider has downloaded
/// four gigabytes nobody asked for.
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

    // MARK: - Which file

    @Test func testASelectedFileIsThePreviewTarget() throws {
        let item = try #require(ColumnPreview.item(selection: ["\(Self.dir)/scan.pdf"],
                                                  deepestRows: Self.rows()))
        #expect(item.path == "\(Self.dir)/scan.pdf")
        #expect(item.name == "scan.pdf")
        // The scalars the identity block renders come across intact — a preview whose caption says
        // nothing is most of the feature missing.
        #expect(item.kind == UTType.pdf.localizedDescription)
        #expect(item.fileSize == 37_000)
        #expect(item.modified == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A folder click opens that folder's own column; a preview beside it would be a second answer
    /// to the same click.
    @Test func testAFolderIsNeverPreviewed() {
        #expect(ColumnPreview.item(selection: ["\(Self.dir)/School"], deepestRows: Self.rows()) == nil)
    }

    /// A ⌘-click multi-selection has no single subject. Previewing the first of it would describe a
    /// file the user never pointed at — and `Set` has no first, so *which* one it described would
    /// vary between renders of the same selection.
    @Test func testAMultiSelectionHasNoPreviewTarget() {
        let selection: Set<String> = ["\(Self.dir)/scan.pdf", "\(Self.dir)/notes.txt"]
        #expect(ColumnPreview.item(selection: selection, deepestRows: Self.rows()) == nil)
    }

    @Test func testAnEmptySelectionHasNoPreviewTarget() {
        #expect(ColumnPreview.item(selection: [], deepestRows: Self.rows()) == nil)
    }

    /// A selection the deepest column doesn't hold is a stale one: clicking a file truncates the
    /// stack to that file's own column, so anything else has already been navigated past. Resolving
    /// it anyway is how a pane ends up previewing a file two columns to the left of the one you are
    /// looking at.
    @Test func testASelectionOutsideTheDeepestColumnIsNotPreviewed() {
        #expect(ColumnPreview.item(selection: ["\(Self.dir)/School/report.pdf"],
                                   deepestRows: Self.rows()) == nil)
    }

    @Test func testAnEmptyColumnHasNothingToPreview() {
        #expect(ColumnPreview.item(selection: ["\(Self.dir)/scan.pdf"], deepestRows: []) == nil)
    }

    /// `FileNode.kind` holds a raw UTI, because that is what the Kind sort and the `kind:` search
    /// filter compare. A caption saying `com.adobe.pdf` — which is what shipped — is the identifier
    /// leaking through to a human.
    @Test func testTheKindReadsAsATypeRatherThanAnIdentifier() throws {
        let described = try #require(ColumnPreviewItem.describe(uti: "com.adobe.pdf"))
        #expect(described == UTType.pdf.localizedDescription)
        #expect(described.contains("com.adobe") == false)
    }

    /// An unrecognised or dynamic type yields nothing at all. Falling back to the raw identifier
    /// would put `dyn.ah62d4rv4ge8086p` under the preview, which says less than an empty line.
    @Test func testAnUnknownTypeIsOmittedRatherThanShownRaw() {
        #expect(ColumnPreviewItem.describe(uti: nil) == nil)
        #expect(ColumnPreviewItem.describe(uti: "") == nil)
        #expect(ColumnPreviewItem.describe(uti: "not a uti at all") == nil)
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
        let item = try #require(ColumnPreview.item(selection: ["\(Self.dir)/scan.pdf"],
                                                   deepestRows: Self.rows()))
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
        // Creation date is why the probe exists at all beyond the flag: `FileNode` doesn't carry it,
        // so the identity block's "Created" row has no other source.
        #expect(present.created != nil)

        let absent = await ColumnPreviewProbe.read(path: dir.appendingPathComponent("gone.txt").path)
        #expect(absent.source == .missing)
        #expect(absent.created == nil)
    }
}
