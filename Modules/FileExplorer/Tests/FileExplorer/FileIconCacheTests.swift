import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The icon cache's key derivation and key→UTType resolution: the pure logic that bounds the cache
/// to one entry per distinct extension (files and directories keyed separately), so a tree of
/// thousands of nodes never grows the cache past a handful of images.
@Suite struct FileIconCacheTests {

    /// Directories key by `/` plus their lowercased extension, so bundles (.app, .photoslibrary) get
    /// their own entry and plain folders share `/`. Files key by their last extension, lowercased;
    /// no extension, or a dotfile, is the generic `""`.
    @Test(arguments: [
        ("Photos", true, "/"), ("Documents", true, "/"),
        ("My App.app", true, "/app"), ("Pictures.photoslibrary", true, "/photoslibrary"),
        ("backup.OLD", true, "/old"),
        ("Report.PDF", false, "pdf"), ("photo.jpeg", false, "jpeg"), ("Notes.TxT", false, "txt"),
        ("a.swift", false, "swift"), ("CompletelyDifferentName.SWIFT", false, "swift"),
        ("backup.tar.gz", false, "gz"),
        ("Makefile", false, ""), (".gitignore", false, ""), ("LICENSE", false, ""),
    ])
    func theKeyIsTheLowercasedExtension(name: String, isDirectory: Bool, key: String) {
        #expect(FileIconCache.cacheKey(name: name, isDirectory: isDirectory) == key)
    }

    @Test func directoryKeysCannotCollideWithAnyFileKey() {
        // "/" is the path separator, so no file name can ever produce a "/"-prefixed extension.
        #expect(FileIconCache.directoryKey == "/")
        #expect(FileIconCache.cacheKey(name: "trailing.dot.", isDirectory: false) != FileIconCache.directoryKey)
        // A directory and a file with the same extension must not share an entry.
        #expect(FileIconCache.cacheKey(name: "a.app", isDirectory: true)
            != FileIconCache.cacheKey(name: "a.app", isDirectory: false))
    }

    @Test func directoryIconTypeResolvesOnlyDeclaredDirectoryTypes() {
        // Plain folders, and folders whose "extension" yields only an undeclared dyn.* type, stay
        // generic: a folder named "v1.2" or "notes.txt" must not pick up a document icon.
        #expect(FileIconCache.iconType(forKey: "/") == .folder)
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
