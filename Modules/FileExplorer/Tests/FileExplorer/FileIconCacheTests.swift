import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// Coverage for the icon cache's key derivation and key→UTType resolution — the pure logic
/// that bounds the cache to one entry per distinct extension (files and directories keyed
/// separately) so 14k-node trees never grow the cache past a handful of images.
@Suite struct FileIconCacheTests {

    @Test func plainDirectoriesShareTheGenericKey() {
        #expect(FileIconCache.cacheKey(name: "Photos", isDirectory: true) == FileIconCache.directoryKey)
        #expect(FileIconCache.cacheKey(name: "Documents", isDirectory: true) == FileIconCache.directoryKey)
    }

    @Test func extensionedDirectoriesKeyByLowercasedExtension() {
        // Bundle-style folders get their own entry so .app/.photoslibrary render as such.
        #expect(FileIconCache.cacheKey(name: "My App.app", isDirectory: true) == "/app")
        #expect(FileIconCache.cacheKey(name: "Pictures.photoslibrary", isDirectory: true) == "/photoslibrary")
        #expect(FileIconCache.cacheKey(name: "backup.OLD", isDirectory: true) == "/old")
        // Distinct from the file namespace: a directory and a file with the same extension
        // must not share an entry.
        #expect(FileIconCache.cacheKey(name: "a.app", isDirectory: true)
            != FileIconCache.cacheKey(name: "a.app", isDirectory: false))
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

    @Test func directoryKeysCannotCollideWithAnyFileKey() {
        // "/" is the path separator, so no file name can ever produce a "/"-prefixed extension.
        #expect(FileIconCache.directoryKey == "/")
        #expect(FileIconCache.cacheKey(name: "trailing.dot.", isDirectory: false) != FileIconCache.directoryKey)
    }

    @Test func directoryIconTypeResolvesOnlyDeclaredDirectoryTypes() {
        // Plain folders and unknown-extension folders stay generic folders…
        #expect(FileIconCache.iconType(forKey: "/") == .folder)
        // …including folders whose "extension" only yields an undeclared dyn.* type
        // (a folder named "v1.2" or "notes.txt" must not pick up a document icon).
        #expect(FileIconCache.iconType(forKey: "/2") == .folder)
        #expect(FileIconCache.iconType(forKey: "/txt") == .folder)
        // Bundle-style extensions resolve to their real (directory-conforming) type.
        #expect(FileIconCache.iconType(forKey: "/app") == UTType(filenameExtension: "app", conformingTo: .directory))
        #expect(FileIconCache.iconType(forKey: "/app").conforms(to: .directory))
        #expect(FileIconCache.iconType(forKey: "/photoslibrary").conforms(to: .directory))
    }

    @Test func fileIconTypeResolvesExtensionWithDataFallback() {
        #expect(FileIconCache.iconType(forKey: "pdf") == .pdf)
        #expect(FileIconCache.iconType(forKey: "") == .data)
    }

    @MainActor
    @Test func iconLookupsForTheSameKeyReturnTheCachedInstance() {
        let first = FileIconCache.icon(name: "a.txt", isDirectory: false)
        let second = FileIconCache.icon(name: "b.TXT", isDirectory: false)
        #expect(first === second)

        let dirA = FileIconCache.icon(name: "Photos", isDirectory: true)
        let dirB = FileIconCache.icon(name: "Documents", isDirectory: true)
        #expect(dirA === dirB)

        let appA = FileIconCache.icon(name: "My App.app", isDirectory: true)
        let appB = FileIconCache.icon(name: "Other.APP", isDirectory: true)
        #expect(appA === appB)
    }
}
