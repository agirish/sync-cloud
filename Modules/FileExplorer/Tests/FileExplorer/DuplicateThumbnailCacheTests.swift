import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// A tile returning to Duplicates paints its cached preview on the first frame, not the file-type
/// icon, by peeking synchronously with `cached`. The risk is the peek and the store spelling the
/// key differently: nothing reports a miss, so these tests hold the two ends together.
///
/// Each test stores on its own shelf, never the app's `NSCache`, which the OS may empty between a
/// store and the next line, and every miss is paired with a hit on the same shelf. See "An NSCache
/// emptied by memory pressure between a store and the next line" in docs/flaky-tests.md.
@MainActor
@Suite struct DuplicateThumbnailCacheTests {

    /// A shelf that keeps everything it is handed for the whole test, which `NSCache` doesn't
    /// promise. One per test (Swift Testing builds the suite afresh for each), so no test answers
    /// another's peek or touches the process-wide shelf.
    @MainActor private final class RetainingStorage: DuplicateThumbnail.Storage {
        private var images: [String: NSImage] = [:]
        func image(forKey key: String) -> NSImage? { images[key] }
        func setImage(_ image: NSImage, forKey key: String) { images[key] = image }
    }

    private let storage = RetainingStorage()

    /// A 1×1 image: only its identity is examined.
    private static func image() -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    private static func path(_ name: String) -> String { "/tmp/duplicate-thumbnail-tests/\(name).pdf" }

    // MARK: The two ends of the lookup

    /// A key nobody has written answers nil, not someone else's picture. Another picture is stored
    /// and found first, since on an empty shelf every key answers nil.
    @Test func anUnknownFileIsACleanMiss() throws {
        let known = Self.image()
        DuplicateThumbnail.store(known, path: Self.path("known"), side: 54, scale: 2, modified: nil,
                                 in: storage)
        try #require(DuplicateThumbnail.cached(path: Self.path("known"), side: 54, scale: 2,
                                               modified: nil, in: storage) === known,
                     "the stored picture was not found — the nil below would say nothing about the key")

        #expect(DuplicateThumbnail.cached(path: Self.path("never-seen"), side: 54, scale: 2,
                                          modified: nil, in: storage) == nil)
    }

    /// Every part of the key counts, so a tile that changed size or display, or whose file was
    /// rewritten, isn't served the previous picture. Three lookups against one entry, so each field
    /// must reach the key; the exact lookup goes first, so the misses are contrasted with a hit.
    @Test func eachPartOfTheKeySeparatesEntries() throws {
        let path = Self.path("varying")
        let stamp = Date(timeIntervalSince1970: 2_000)
        let image = Self.image()
        DuplicateThumbnail.store(image, path: path, side: 54, scale: 2, modified: stamp, in: storage)
        try #require(DuplicateThumbnail.cached(path: path, side: 54, scale: 2, modified: stamp,
                                               in: storage) === image,
                     "the peek missed an entry the store just wrote — the two spell the key differently, and every nil below would pass with the entry gone")

        #expect(DuplicateThumbnail.cached(path: path, side: 96, scale: 2, modified: stamp,
                                          in: storage) == nil,
                "a different tile size was served the picture rendered for another one")
        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 1, modified: stamp,
                                          in: storage) == nil,
                "a different display scale was served the picture rendered for another one")
        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 2,
                                          modified: Date(timeIntervalSince1970: 3_000),
                                          in: storage) == nil,
                "a rewritten file was served the preview of its previous contents")
    }

    // MARK: What the tile draws

    /// The tile paints from the cache on its first body pass, before any task runs. Never mounted,
    /// so `image` is nil as on the first render after a workspace switch. The store uses
    /// `tile.previewScale`, not a literal: `@Environment` is unpopulated off the view tree, so the
    /// tile's own answer is the one the peek and the task must agree on.
    @Test func theTilePaintsFromTheCacheBeforeAnyTaskRuns() {
        let path = Self.path("first-pass")
        let tile = DuplicateThumbnailView(path: path, name: "first-pass.pdf",
                                          isKeeper: false, modified: nil, previews: storage)
        #expect(tile.shownImage == nil, "the tile drew a picture before anything was stored")

        let image = Self.image()
        DuplicateThumbnail.store(image, path: path, side: tile.side,
                                 scale: tile.previewScale, modified: nil, in: storage)

        #expect(tile.shownImage === image,
                "a returning tile drew the file-type icon over a preview already in the cache")
    }

    /// A tile told not to load previews doesn't get one from the cache either. `loadsPreview` caps a
    /// large group's pictures, and a peek ahead of that guard would reinstate any another card had
    /// rendered. A twin that does load previews finds the entry first, so the nil is the guard.
    @Test func aTileThatSkipsPreviewsStaysOnItsIcon() throws {
        let path = Self.path("no-preview")
        let tile = DuplicateThumbnailView(path: path, name: "no-preview.pdf", isKeeper: false,
                                          modified: nil, loadsPreview: false, previews: storage)
        let twin = DuplicateThumbnailView(path: path, name: "no-preview.pdf", isKeeper: false,
                                          modified: nil, previews: storage)
        let image = Self.image()
        DuplicateThumbnail.store(image, path: path, side: tile.side,
                                 scale: tile.previewScale, modified: nil, in: storage)
        try #require(twin.shownImage === image,
                     "a tile that does load previews missed the entry — the nil below would be vacuous")

        #expect(tile.shownImage == nil,
                "the cache peek ran ahead of the loadsPreview guard")
    }

    // MARK: The shelf the app uses

    /// A tile looks on the shared shelf unless handed another. The tests above all hand in their
    /// own, so only this sees the default, the `static` cache that outlives the views. Pinned by
    /// identity, not by storing into it, because the OS may take back what is stored there.
    @Test func aTileLooksOnTheSharedShelfUnlessHandedAnother() {
        let tile = DuplicateThumbnailView(path: Self.path("default"), name: "default.pdf",
                                          isKeeper: false, modified: nil)
        #expect(tile.previews === DuplicateThumbnail.imageCache,
                "a tile no longer reads the shared cache — it will find nothing after a workspace switch")
    }
}
