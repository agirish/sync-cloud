import Testing
import AppKit
@testable import Dashboard

/// Pins DetailsMetadataCache (extracted from DetailsSidebar's view body): per-path
/// memoization and the two invalidation gestures — a refreshSubject event and a scan
/// completing. The scan trigger is deliberately one-sided: only isScanning flipping to
/// false drops the cache; a scan starting must not.
@MainActor
@Suite struct DetailsMetadataCacheTests {

    /// Injected metadata loader that counts stat calls and returns configurable values,
    /// standing in for DetailsSidebar.loadMetadata(for:).
    @MainActor
    final class CountingLoader {
        private(set) var statCount = 0
        var size = "1 KB"
        var modificationDate = "Jul 1, 2026 at 10:00:00 AM"

        func load(_ path: String) -> DetailsSidebar.FileMetadata? {
            statCount += 1
            return DetailsSidebar.FileMetadata(
                name: (path as NSString).lastPathComponent,
                path: path,
                kind: "Document",
                size: size,
                creationDate: "Jan 1, 2026 at 9:00:00 AM",
                modificationDate: modificationDate,
                permissions: "644",
                isDirectory: false
            )
        }
    }

    private func makeCache(loader: CountingLoader) -> DetailsMetadataCache {
        DetailsMetadataCache(loadMetadata: loader.load, loadIcon: { _ in NSImage() })
    }

    @Test func repeatedLookupsForSamePathStatOnce() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        let first = cache.data(for: "/vault/report.pdf")
        _ = cache.data(for: "/vault/report.pdf")
        let third = cache.data(for: "/vault/report.pdf")

        #expect(loader.statCount == 1)
        #expect(first.metadata?.path == "/vault/report.pdf")
        #expect(third.metadata?.size == "1 KB")
        #expect(third.icon != nil)
    }

    @Test func refreshEventInvalidatesAndNextLookupRestats() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = cache.data(for: "/vault/report.pdf")
        cache.refreshOccurred()
        _ = cache.data(for: "/vault/report.pdf")

        #expect(loader.statCount == 2)
    }

    @Test func scanCompletionInvalidatesButScanStartDoesNot() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = cache.data(for: "/vault/report.pdf")

        // Scan starting: the memoized metadata must survive.
        cache.scanningChanged(true)
        _ = cache.data(for: "/vault/report.pdf")
        #expect(loader.statCount == 1)

        // Scan completing: the next lookup must re-stat.
        cache.scanningChanged(false)
        _ = cache.data(for: "/vault/report.pdf")
        #expect(loader.statCount == 2)
    }

    @Test func pathChangeRestats() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = cache.data(for: "/vault/a.txt")
        let second = cache.data(for: "/vault/b.txt")

        #expect(loader.statCount == 2)
        #expect(second.metadata?.name == "b.txt")

        // Switching back is a path change too — the cache holds a single entry.
        _ = cache.data(for: "/vault/a.txt")
        #expect(loader.statCount == 3)
    }

    @Test func invalidationSurfacesFreshLoaderValues() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        let stale = cache.data(for: "/vault/report.pdf")
        #expect(stale.metadata?.size == "1 KB")

        // The file changed on disk (e.g. a copy overwrote it); the loader now sees new attributes.
        loader.size = "2 MB"
        loader.modificationDate = "Jul 6, 2026 at 3:00:00 PM"

        // Without invalidation the memoized values keep being served.
        let memoized = cache.data(for: "/vault/report.pdf")
        #expect(memoized.metadata?.size == "1 KB")

        cache.refreshOccurred()
        let fresh = cache.data(for: "/vault/report.pdf")
        #expect(fresh.metadata?.size == "2 MB")
        #expect(fresh.metadata?.modificationDate == "Jul 6, 2026 at 3:00:00 PM")
    }

    /// The computed-directory-size task keys on `generation`, so the same events that drop the
    /// memoized metadata must bump it — that is what clears a stale folder total after a
    /// copy/delete inside the selected folder and triggers the recompute.
    @Test func generationBumpsOnRefreshAndScanCompletionOnly() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        #expect(cache.generation == 0)

        cache.refreshOccurred()
        #expect(cache.generation == 1)

        // Scan starting keeps the metadata cache — and must keep the computed size too.
        cache.scanningChanged(true)
        #expect(cache.generation == 1)

        cache.scanningChanged(false)
        #expect(cache.generation == 2)
    }

    /// Lookups (hits or path changes) must not bump the generation, or every selection change
    /// would needlessly restart the directory-size walk twice.
    @Test func lookupsDoNotBumpGeneration() {
        let loader = CountingLoader()
        let cache = makeCache(loader: loader)

        _ = cache.data(for: "/vault/a.txt")
        _ = cache.data(for: "/vault/a.txt")
        _ = cache.data(for: "/vault/b.txt")

        #expect(cache.generation == 0)
    }

    @Test func missingPathMemoizesNilResult() {
        let loader = CountingLoader()
        let cache = DetailsMetadataCache(
            loadMetadata: { path in _ = loader.load(path); return nil },
            loadIcon: { _ in NSImage() }
        )

        let first = cache.data(for: "/vault/gone.txt")
        let second = cache.data(for: "/vault/gone.txt")

        #expect(first.metadata == nil)
        #expect(first.icon == nil)
        #expect(second.metadata == nil)
        #expect(loader.statCount == 1)
    }
}
