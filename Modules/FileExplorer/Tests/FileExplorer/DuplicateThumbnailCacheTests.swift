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
@MainActor
@Suite struct DuplicateThumbnailCacheTests {

    /// A 1×1 image — the content is never examined, only its identity.
    private static func image() -> NSImage {
        NSImage(size: NSSize(width: 1, height: 1))
    }

    /// A path per test, so one test's warm cache cannot answer another's lookup. The cache is
    /// process-wide `static` state and the suite runs in one process.
    private static func path(_ name: String) -> String { "/tmp/duplicate-thumbnail-tests/\(name).pdf" }

    // MARK: The two ends of the lookup

    /// The peek finds what the store put there. This is the whole mechanism.
    @Test func aStoredPreviewIsFoundByTheSynchronousPeek() {
        let path = Self.path("stored")
        let stamp = Date(timeIntervalSince1970: 1_000)
        DuplicateThumbnail.store(Self.image(), path: path, side: 54, scale: 2, modified: stamp)

        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 2, modified: stamp) != nil,
                "the peek missed an entry the store just wrote — the two spell the key differently")
    }

    /// A key nobody has written answers nil rather than someone else's picture.
    @Test func anUnknownFileIsACleanMiss() {
        #expect(DuplicateThumbnail.cached(path: Self.path("never-seen"), side: 54, scale: 2,
                                          modified: nil) == nil)
    }

    /// **Every component of the key is load-bearing**, so a tile that changed size, moved to another
    /// display, or whose file was rewritten does not get served the previous picture.
    ///
    /// Written as three separate lookups against one stored entry rather than three stored entries,
    /// because what is being pinned is that each field REACHES the key — an implementation that
    /// dropped `side` would still pass a test that only ever varied `path`.
    @Test func eachPartOfTheKeySeparatesEntries() {
        let path = Self.path("varying")
        let stamp = Date(timeIntervalSince1970: 2_000)
        DuplicateThumbnail.store(Self.image(), path: path, side: 54, scale: 2, modified: stamp)

        #expect(DuplicateThumbnail.cached(path: path, side: 96, scale: 2, modified: stamp) == nil,
                "a different tile size was served the picture rendered for another one")
        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 1, modified: stamp) == nil,
                "a different display scale was served the picture rendered for another one")
        #expect(DuplicateThumbnail.cached(path: path, side: 54, scale: 2,
                                          modified: Date(timeIntervalSince1970: 3_000)) == nil,
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
                                          isKeeper: false, modified: nil)
        #expect(tile.shownImage == nil, "the cache was warm before this test wrote to it")

        DuplicateThumbnail.store(Self.image(), path: path, side: tile.side,
                                 scale: tile.previewScale, modified: nil)

        #expect(tile.shownImage != nil,
                "a returning tile drew the file-type icon over a preview already in the cache")
    }

    /// **A tile that was told not to load previews does not get one from the cache either.**
    ///
    /// `loadsPreview` is the cap on a forty-copy group — the tile is still the picker, only the
    /// picture is skipped. A peek placed ahead of that guard would reinstate the pictures it exists
    /// to withhold, for every copy whose preview some other card had already caused to be rendered.
    @Test func aTileThatSkipsPreviewsStaysOnItsIcon() {
        let path = Self.path("no-preview")
        let tile = DuplicateThumbnailView(path: path, name: "no-preview.pdf",
                                          isKeeper: false, modified: nil, loadsPreview: false)
        DuplicateThumbnail.store(Self.image(), path: path, side: tile.side,
                                 scale: tile.previewScale, modified: nil)

        #expect(tile.shownImage == nil,
                "the cache peek ran ahead of the loadsPreview guard")
    }
}
