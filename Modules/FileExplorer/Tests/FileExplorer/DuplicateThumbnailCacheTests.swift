import AppKit
import SwiftUI
import Testing
@testable import FileExplorer

/// **The file-icon flash on returning to Duplicates**, and the fact that made it look like
/// something it was not.
///
/// Leaving Organize destroys `LensWorkspaceView` and every `DuplicateThumbnailView` under it, so on
/// the way back each tile is constructed fresh with `image` nil. It reads as "the thumbnails are
/// reloading" — and they are not: `DuplicateThumbnail.imageCache` is `static`, so it outlived the
/// teardown and is still holding the answer. What was missing was a way to *ask* it without
/// suspending. `image(path:…)` is `async`, so the earliest a tile could reach it was a `.task`,
/// which runs after the first render — one frame of the generic file-type icon, per tile, for a
/// picture already decoded and in memory.
///
/// So the whole of the fix is a synchronous peek, and the whole of the risk in it is that the peek
/// and the store can spell the key differently. That failure is invisible in the worst way: the
/// cache still fills, `cached` still returns nil, the tile still draws the icon, and nothing
/// anywhere reports a miss. These tests exist to hold the two ends together.
///
/// **Every test here stores on a shelf of its own, never on the app's.** The app's is an `NSCache`,
/// and the OS may empty it between a store and the very next line: on 2026-09-26 a memory-pressure
/// warning froze it at the zero entries it held, and two of these tests went red on CI blaming the
/// key — while the three asserting a *miss* passed, having examined nothing. Only where an entry is
/// kept is the test's. Every store and peek still goes through the production `store` and `cached`,
/// so the key at both ends is production's spelling, and every miss asserted here is paired with a
/// hit on the same shelf. See "An NSCache emptied by memory pressure between a store and the next
/// line" in docs/flaky-tests.md.
@MainActor
@Suite struct DuplicateThumbnailCacheTests {

    /// A shelf that keeps everything it is handed for as long as the test runs — what `NSCache`
    /// promises not to do.
    ///
    /// One per test: Swift Testing builds the suite afresh for each, so no test's store can answer
    /// another's peek, and nothing here touches the process-wide shelf other suites render from.
    @MainActor private final class RetainingStorage: DuplicateThumbnail.Storage {
        private var images: [String: NSImage] = [:]
        func image(forKey key: String) -> NSImage? { images[key] }
        func setImage(_ image: NSImage, forKey key: String) { images[key] = image }
    }

    private let storage = RetainingStorage()

    /// A 1×1 image — the content is never examined, only its identity.
    private static func image() -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    private static func path(_ name: String) -> String { "/tmp/duplicate-thumbnail-tests/\(name).pdf" }

    // MARK: The two ends of the lookup

    /// The peek finds what the store put there. This is the whole mechanism.
    @Test func aStoredPreviewIsFoundByTheSynchronousPeek() {
        let path = Self.path("stored")
        let stamp = Date(timeIntervalSince1970: 1_000)
        let image = Self.image()
        DuplicateThumbnail.store(image, path: path, side: 54, scale: 2, modified: stamp, in: storage)

        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 2, modified: stamp,
                                          in: storage) === image,
                "the peek missed an entry the store just wrote — the two spell the key differently")
    }

    /// A key nobody has written answers nil rather than someone else's picture.
    ///
    /// Asked with someone else's picture on the shelf, and that picture found first: against an
    /// empty shelf every key answers nil, whatever the key is made of.
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

    /// **Every component of the key is load-bearing**, so a tile that changed size, moved to another
    /// display, or whose file was rewritten does not get served the previous picture.
    ///
    /// Written as three separate lookups against one stored entry rather than three stored entries,
    /// because what is being pinned is that each field REACHES the key — an implementation that
    /// dropped `side` would still pass a test that only ever varied `path`. The exact lookup goes
    /// first: the three misses mean something only while the entry they are contrasted with is there.
    @Test func eachPartOfTheKeySeparatesEntries() throws {
        let path = Self.path("varying")
        let stamp = Date(timeIntervalSince1970: 2_000)
        let image = Self.image()
        DuplicateThumbnail.store(image, path: path, side: 54, scale: 2, modified: stamp, in: storage)
        try #require(DuplicateThumbnail.cached(path: path, side: 54, scale: 2, modified: stamp,
                                               in: storage) === image,
                     "the exact key missed — every nil below would pass with the entry gone")

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

    /// **The tile paints from the cache on its FIRST body pass**, with no task having run.
    ///
    /// The view is never mounted here, which is the point: `image` is nil exactly as it is on the
    /// first render after a workspace switch, and `shownImage` has to answer anyway.
    ///
    /// The store is keyed on `tile.previewScale` rather than on a scale written out here, and that
    /// is not convenience — `@Environment` is unpopulated off the view tree, so the scale this tile
    /// actually resolves is not something the test may assume. Asking the tile is also what makes
    /// this test fail if the peek and the task ever stop agreeing about it.
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

    /// **A tile that was told not to load previews does not get one from the cache either.**
    ///
    /// `loadsPreview` is the cap on a forty-copy group — the tile is still the picker, only the
    /// picture is skipped. A peek placed ahead of that guard would reinstate the pictures it exists
    /// to withhold, for every copy whose preview some other card had already caused to be rendered.
    ///
    /// A twin that does load previews finds the entry first, so the nil is the guard speaking, not a
    /// store that landed somewhere this tile was never going to look.
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

    /// **A tile looks on the one shared shelf unless it is handed another.**
    ///
    /// Every test above hands the tile a shelf of its own, so none of them can see the default —
    /// and the default is the fix: `DuplicateThumbnail.imageCache` is `static` and outlives the
    /// views, which is the only reason a tile built after a workspace switch has anything to find.
    /// A default that gave each tile a fresh shelf would pass every test above and flash the icon on
    /// every return. Pinned by identity rather than by storing into it, because what is stored
    /// there is exactly what the OS may take back.
    @Test func aTileLooksOnTheSharedShelfUnlessHandedAnother() {
        let tile = DuplicateThumbnailView(path: Self.path("default"), name: "default.pdf",
                                          isKeeper: false, modified: nil)
        #expect(tile.previews === DuplicateThumbnail.imageCache,
                "a tile no longer reads the shared cache — it will find nothing after a workspace switch")
    }
}
