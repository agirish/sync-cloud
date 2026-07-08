import Testing
@testable import FileExplorer

/// Coverage for the icon cache's key derivation — the pure logic that bounds the cache
/// to one entry per distinct extension (plus one shared directory entry) so 14k-node
/// trees never grow the cache past a handful of images.
@Suite struct FileIconCacheTests {

    @Test func directoriesAllShareOneKey() {
        #expect(FileIconCache.cacheKey(name: "Photos", isDirectory: true) == FileIconCache.directoryKey)
        // Even a directory whose name looks like it has an extension.
        #expect(FileIconCache.cacheKey(name: "backup.old", isDirectory: true) == FileIconCache.directoryKey)
        #expect(FileIconCache.cacheKey(name: "My App.app", isDirectory: true) == FileIconCache.directoryKey)
    }

    @Test func fileKeyIsLowercasedExtension() {
        #expect(FileIconCache.cacheKey(name: "Report.PDF", isDirectory: false) == "pdf")
        #expect(FileIconCache.cacheKey(name: "photo.jpeg", isDirectory: false) == "jpeg")
        #expect(FileIconCache.cacheKey(name: "Notes.TxT", isDirectory: false) == "txt")
    }

    @Test func sameExtensionCollapsesToOneKey() {
        let a = FileIconCache.cacheKey(name: "a.swift", isDirectory: false)
        let b = FileIconCache.cacheKey(name: "CompletelyDifferentName.SWIFT", isDirectory: false)
        #expect(a == b)
    }

    @Test func onlyLastExtensionComponentCounts() {
        #expect(FileIconCache.cacheKey(name: "backup.tar.gz", isDirectory: false) == "gz")
    }

    @Test func extensionlessFilesAndDotfilesShareTheGenericKey() {
        #expect(FileIconCache.cacheKey(name: "Makefile", isDirectory: false) == "")
        #expect(FileIconCache.cacheKey(name: ".gitignore", isDirectory: false) == "")
        #expect(FileIconCache.cacheKey(name: "LICENSE", isDirectory: false) == "")
    }

    @Test func directoryKeyCannotCollideWithAnyFileKey() {
        // "/" is the path separator, so no file name can ever produce it as an extension.
        #expect(FileIconCache.directoryKey == "/")
        #expect(FileIconCache.cacheKey(name: "trailing.dot.", isDirectory: false) != FileIconCache.directoryKey)
    }

    @MainActor
    @Test func iconLookupsForTheSameKeyReturnTheCachedInstance() {
        let first = FileIconCache.icon(name: "a.txt", isDirectory: false)
        let second = FileIconCache.icon(name: "b.TXT", isDirectory: false)
        #expect(first === second)

        let dirA = FileIconCache.icon(name: "Photos", isDirectory: true)
        let dirB = FileIconCache.icon(name: "Documents", isDirectory: true)
        #expect(dirA === dirB)
    }
}
