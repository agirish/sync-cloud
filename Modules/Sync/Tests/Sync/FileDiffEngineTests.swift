import Testing
import Foundation
@testable import Sync

@Suite struct FileDiffEngineTests {

    @Test func getFilesInDirectoryCapsALinkToAnAncestorWithoutOverExpanding() throws {
        // A symlink pointing at a real ancestor (`a/b/link -> a`) must be capped immediately, as
        // `buildTree` does — not expanded a full extra level (`a/b/link/b/…`) before the target
        // guard catches it. Real `FileManager` on a temp dir: mock disks can't hold symlinks.
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "DiffSymlinkTests")
        defer { try? fm.removeItem(at: root) }

        let b = root.appendingPathComponent("a/b")
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try "x".write(to: b.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: b.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("a"))

        let keys = Set(try FileDiffEngine.getFilesInDirectory(root).keys)

        #expect(keys.contains("a/b/leaf.txt"))
        #expect(keys.contains("a/b/link"))                       // the link is listed as a directory…
        #expect(!keys.contains { $0.hasPrefix("a/b/link/") })    // …but never descended into (no phantom rows)
    }

    /// The URL enumerator refuses to enter a symlinked folder and reports it as an error; the
    /// manual descent then walks the target. The folder must come out explored, with its
    /// contents, or the diff suppresses every Missing row beneath it, as a Compare at the iCloud
    /// Drive container would over its linked `Documents`.
    @Test func aSymlinkedFolderTheWalkDescendsIsNotMarkedUnexplored() throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "DiffSymlinkTests")
        defer { try? fm.removeItem(at: root) }
        let container = root.appendingPathComponent("container")
        let target = root.appendingPathComponent("outside").appendingPathComponent("Documents")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: target)

        let files = try FileDiffEngine.getFilesInDirectory(container)
        let documents = try #require(files["Documents"])
        #expect(documents.isDirectory)
        #expect(!documents.isUnexplored, "the link's descent error was recorded as an unreadable directory")
        #expect(files["Documents/note.txt"] != nil)
        #expect(files[""] == nil, "the walk root was marked unexplored")
    }

    /// The same link as the walk's root: a Compare focused on iCloud Drive → Documents, with the
    /// scan path spelled through the container. The enumerator lists nothing at a root whose last
    /// component is a link (ENOTDIR), and the forgiveness above is right only for a link the walk
    /// then descends. Unless the root is walked where it leads, the side reads as authoritatively
    /// empty and everything on the other side becomes "Folder missing on left".
    @Test func aWalkRootedAtALinkToAFolderListsTheFolder() throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "DiffSymlinkTests")
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("outside").appendingPathComponent("Documents")
        let link = root.appendingPathComponent("container").appendingPathComponent("Documents")
        try fm.createDirectory(at: target.appendingPathComponent("Family"), withIntermediateDirectories: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("Family/note.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let files = try FileDiffEngine.getFilesInDirectory(link)

        #expect(!files.isEmpty || files[""]?.isUnexplored == true,
                "an empty map with no unexplored root reads as an empty folder")
        #expect(files["Family"]?.isDirectory == true)
        #expect(files["Family/note.txt"] != nil, "the walk did not list what the link leads to")
        #expect(files[""] == nil, "a root the walk could read was marked unexplored")
    }

    // MARK: - Helpers

    /// One entry on the mock disk: a folder or a file, with the date and size its walk reads.
    struct Stub: Sendable {
        let path: String
        let isDirectory: Bool
        var date: Date? = nil
        var size: Int? = nil

        static func dir(_ path: String, date: Date? = nil) -> Stub {
            Stub(path: path, isDirectory: true, date: date)
        }
        static func file(_ path: String, date: Date? = nil, size: Int? = nil) -> Stub {
            Stub(path: path, isDirectory: false, date: date, size: size)
        }
    }

    /// A mock disk holding `/src`, `/dst` and `stubs`. The mock models no intermediate folders, so
    /// each folder a file sits in is a stub of its own.
    private func disk(_ stubs: [Stub]) -> MockFileManager {
        let fm = MockFileManager()
        for stub in [Stub.dir("/src"), .dir("/dst")] + stubs {
            var attributes: [FileAttributeKey: Any] = [:]
            if let date = stub.date { attributes[.modificationDate] = date }
            if let size = stub.size { attributes[.size] = size }
            fm.virtualDisk[stub.path] = MockFileManager.FileStub(
                isDirectory: stub.isDirectory, attributes: attributes.isEmpty ? nil : attributes,
                contents: stub.isDirectory ? [] : nil)
        }
        return fm
    }

    private func makeProviders() -> (CloudProvider, CloudProvider) {
        (CloudProvider(id: "src", displayName: "Source", imageName: "folder", rootPath: "/src", type: .iCloud),
         CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", rootPath: "/dst", type: .iCloud))
    }

    /// Walks `/src` (Source, on the left) and `/dst` (Dest, on the right) and compares them.
    private func diff(_ fm: MockFileManager, caseInsensitive: Bool = false) throws -> [FileDifference] {
        let (srcProvider, dstProvider) = makeProviders()
        return FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: fm),
            rightFilesInfo: try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: fm),
            caseInsensitive: caseInsensitive)
    }

    @Test func testMissingFilesCarryTheirExistingSideSize() async throws {
        // A file that exists on only one side must still report its size, so the Differences
        // list can show it instead of "—". A missing folder has no byte size and stays nil.
        let now = Date()
        let diffs = try diff(disk([.file("/src/only-left.txt", date: now, size: 4096),
                                   .file("/dst/only-right.txt", date: now, size: 8192),
                                   .dir("/src/folderOnly")]))
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })

        // Missing on right: the item lives on the left, so its left size travels with the diff.
        #expect(byPath["only-left.txt"]?.type == .missingOnRight)
        #expect(byPath["only-left.txt"]?.leftFileSize == 4096)
        #expect(byPath["only-left.txt"]?.rightFileSize == nil)

        // Missing on left: mirror — the right size travels with the diff.
        #expect(byPath["only-right.txt"]?.type == .missingOnLeft)
        #expect(byPath["only-right.txt"]?.rightFileSize == 8192)
        #expect(byPath["only-right.txt"]?.leftFileSize == nil)

        // A missing folder carries no byte size (rendered "—", with the roll-up in the Change column).
        #expect(byPath["folderOnly"]?.type == .missingOnRight)
        #expect(byPath["folderOnly"]?.leftFileSize == nil)
    }

    @Test func testEmptyDirectorySync() async throws {
        let mockFM = disk([.dir("/src/empty_folder")])

        // Verify the empty folder is found by scan
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        #expect(srcFiles["empty_folder"] != nil)
        #expect(srcFiles["empty_folder"]?.isDirectory == true)

        // Should find 1 difference (the missing directory)
        let diffs = try diff(mockFM)
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "empty_folder")
        #expect(diffs.first?.action == .copyToRight)
    }

    @Test func testMissingModificationDateFallback() async throws {
        // Simulating POSIX attributes or system aliases where modificationDate is missing (nil).
        // Despite the missing dates, the size discrepancy forces a sync.
        let diffs = try diff(disk([.file("/src/nometa.txt", size: 500), .file("/dst/nometa.txt", size: 1000)]))

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "nometa.txt")
        #expect(diffs.first?.description == "Sizes differ and neither file has a date — choose which to keep")
        #expect(diffs.first?.heldBack == .sizesDifferWithoutANewerSide)
        #expect(diffs.first?.action == .copyToRight) // Defaults to source-truth on tie
    }

    @Test func testDeepNestedDirectorySync() async throws {
        let mockFM = MockFileManager()
        let root = URL(fileURLWithPath: "/src")
        try mockFM.createDirectory(at: root, withIntermediateDirectories: true)
        
        // Create 10 levels of nesting
        var currentURL = root
        for i in 1...10 {
            currentURL = currentURL.appendingPathComponent("level_\(i)")
            try mockFM.createDirectory(at: currentURL, withIntermediateDirectories: true)
            
            // Add a file at each level
            let fileURL = currentURL.appendingPathComponent("file_\(i).txt")
            mockFM.virtualDisk[fileURL.path] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(root, fileManager: mockFM)
        
        // Should find 10 files and 10 directories (excluding root)
        // Note: the engine returns a flat dictionary of relative paths
        #expect(srcFiles.count == 20)
        
        // Verify a deep file is present
        #expect(srcFiles["level_1/level_2/level_3/level_4/level_5/level_6/level_7/level_8/level_9/level_10/file_10.txt"] != nil)
    }

    @Test func testHiddenFilesDetection() async throws {
        let mockFM = MockFileManager()
        let root = URL(fileURLWithPath: "/src")
        try mockFM.createDirectory(at: root, withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/.gitignore"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // getFilesInDirectory returns all files (including hidden); filtering by showHidden happens in applyFilters().
        let files = try FileDiffEngine.getFilesInDirectory(root, fileManager: mockFM)
        #expect(files.count == 2)
        #expect(files[".gitignore"] != nil)
        #expect(files["visible.txt"] != nil)
    }

    // MARK: - Direction of resolution
    // Both directions of each branch, so a sign-flip (syncing the wrong way, overwriting newer
    // data with older) can't pass silently.

    /// Same type (both files), same size: the newer side is copied over the older.
    @Test(arguments: [false, true])
    func testSameTypeNewerSideWins(leftIsNewer: Bool) async throws {
        let older = Date(timeIntervalSince1970: 2_000)
        let newer = older.addingTimeInterval(10)
        let diffs = try diff(disk([.file("/src/doc.txt", date: leftIsNewer ? newer : older, size: 100),
                                   .file("/dst/doc.txt", date: leftIsNewer ? older : newer, size: 100)]))

        #expect(diffs.count == 1)
        #expect(diffs.first?.action == (leftIsNewer ? .copyToRight : .copyToLeft))
        #expect(diffs.first?.description == (leftIsNewer ? "Source file is newer" : "Dest file is newer"))
    }

    static let folderInDest = "Folder in Dest, file in Source — a folder’s date is not when its contents changed; choose which to keep"
    static let folderInSource = "Folder in Source, file in Dest — a folder’s date is not when its contents changed; choose which to keep"

    /// A folder and a file at one path, and the single row they must produce. A nil field isn't
    /// asserted.
    struct Mismatch: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let stubs: [Stub]
        var caseInsensitive = false
        let path: String
        var type: FileDifference.DifferenceType? = nil
        var action: FileDifference.SyncAction? = nil
        var description: String? = nil
        var heldBack: FileDifference.HeldBack? = nil
        var enclosed: Int? = nil
        var leftItemPath: String? = nil
        var rightItemPath: String? = nil
    }

    // A folder that pairs with a FILE on the other side resolves with a single action on its
    // row (dir wins: recursive copy; file wins: the subtree is replaced wholesale). Its
    // descendants must therefore collapse into that row like a missing folder's do — separate
    // child rows double-copy after a dir-wins sync, race the parent's replace op in parallel
    // bulk sync, and go stale after a file-wins sync.
    static let mismatches: [Mismatch] = {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = older.addingTimeInterval(10)
        return [
            Mismatch(testDescription: "a newer folder on the right wins",
                     stubs: [.file("/src/mismatch", date: older), .dir("/dst/mismatch", date: newer)],
                     path: "mismatch", action: .copyToLeft, description: folderInDest, heldBack: .folderVersusFile),
            Mismatch(testDescription: "on a date tie the folder wins",
                     stubs: [.dir("/src/mismatch"), .file("/dst/mismatch")],
                     path: "mismatch", action: .copyToRight, description: folderInSource, heldBack: .folderVersusFile),
            Mismatch(testDescription: "a newer file on the left wins",
                     stubs: [.file("/src/mismatch", date: newer), .dir("/dst/mismatch", date: older)],
                     path: "mismatch", action: .copyToRight, description: folderInDest, heldBack: .folderVersusFile),
            // Dates tie, so the folder side wins.
            Mismatch(testDescription: "the folder side's children fold into the row",
                     stubs: [.dir("/src/Bundle"), .file("/src/Bundle/a.txt"), .file("/src/Bundle/b.txt"),
                             .file("/dst/Bundle")],
                     path: "Bundle", type: .differentDates, action: .copyToRight, enclosed: 2),
            // The newer file flips the action, but the children must still fold in: they'd
            // otherwise point at paths the winning file is about to replace.
            Mismatch(testDescription: "the children fold in when the file wins too",
                     stubs: [.dir("/src/Bundle", date: Date(timeIntervalSince1970: 10_000)),
                             .file("/src/Bundle/a.txt"), .file("/src/Bundle/b.txt"),
                             .file("/dst/Bundle", date: Date(timeIntervalSince1970: 10_010))],
                     path: "Bundle", action: .copyToLeft, description: folderInSource,
                     heldBack: .folderVersusFile, enclosed: 2),
            // Mirror: the folder's children surface as missingOnLeft rows. Dates tie.
            Mismatch(testDescription: "a folder on the right folds its children in",
                     stubs: [.file("/src/Bundle"), .dir("/dst/Bundle"), .file("/dst/Bundle/p.jpg"),
                             .file("/dst/Bundle/q.jpg")],
                     path: "Bundle", action: .copyToLeft, enclosed: 2),
            // A missing folder inside rolls up into the top-most row rather than surviving as a
            // partly collapsed subtree: a.txt, Sub, Sub/deep.txt.
            Mismatch(testDescription: "a missing folder inside folds in whole",
                     stubs: [.dir("/src/Bundle"), .dir("/src/Bundle/Sub"), .file("/src/Bundle/a.txt"),
                             .file("/src/Bundle/Sub/deep.txt"), .file("/dst/Bundle")],
                     path: "Bundle", enclosed: 3),
            // Case-insensitive matching pairs file "Report" with folder "report"; the row carries
            // the left path while the children carry the right-side casing. Dates tie.
            Mismatch(testDescription: "a case-variant folder folds its children in",
                     stubs: [.file("/src/Report"), .dir("/dst/report"), .file("/dst/report/x.txt"),
                             .file("/dst/report/y.txt")],
                     caseInsensitive: true, path: "Report", type: .differentDates, action: .copyToLeft,
                     enclosed: 2, leftItemPath: "/src/Report", rightItemPath: "/dst/report"),
        ]
    }()

    @Test(arguments: mismatches)
    func aFolderAgainstAFileIsOneRow(_ c: Mismatch) async throws {
        let diffs = try diff(disk(c.stubs), caseInsensitive: c.caseInsensitive)

        #expect(diffs.count == 1)
        let row = try #require(diffs.first)
        #expect(row.relativePath == c.path)
        if let type = c.type { #expect(row.type == type) }
        if let action = c.action { #expect(row.action == action) }
        if let description = c.description { #expect(row.description == description) }
        if let heldBack = c.heldBack { #expect(row.heldBack == heldBack) }
        if let enclosed = c.enclosed { #expect(row.enclosedItemCount == enclosed) }
        if let leftItemPath = c.leftItemPath { #expect(row.leftItemPath == leftItemPath) }
        if let rightItemPath = c.rightItemPath { #expect(row.rightItemPath == rightItemPath) }
    }

    // MARK: - Missing-folder collapse
    // A folder missing on one side is synced with a single recursive copy, so its contents
    // must not appear as separate differences: they'd double-copy during bulk sync and leave
    // stale rows (with spurious overwrite prompts) after the folder entry is synced.

    @Test(arguments: [true, false])
    func testMissingFolderCollapsesContentsIntoSingleEntry(missingOnTheRight: Bool) async throws {
        let diffs = try diff(disk(missingOnTheRight
            ? [.dir("/src/Music"), .dir("/src/Music/Inner"), .file("/src/Music/a.mp3"),
               .file("/src/Music/b.mp3"), .file("/src/Music/Inner/c.mp3")]
            : [.dir("/dst/Photos"), .file("/dst/Photos/p1.jpg")]))

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == (missingOnTheRight ? "Music" : "Photos"))
        #expect(diffs.first?.type == (missingOnTheRight ? .missingOnRight : .missingOnLeft))
        #expect(diffs.first?.action == (missingOnTheRight ? .copyToRight : .copyToLeft))
        // On the right, 4 collapsed items: a.mp3, b.mp3, Inner, Inner/c.mp3
        #expect(diffs.first?.enclosedItemCount == (missingOnTheRight ? 4 : 1))
    }

    @Test func testCollapseKeepsUnrelatedDifferences() async throws {
        let now = Date()
        let diffs = try diff(disk([
            .dir("/src/Music"), .file("/src/Music/a.mp3"),
            // A sibling file missing on right — not inside the missing folder, must survive.
            .file("/src/loose.txt"),
            // A changed file present on both sides must survive too.
            .file("/src/shared.txt", date: now.addingTimeInterval(10), size: 10),
            .file("/dst/shared.txt", date: now, size: 10),
        ]))

        #expect(diffs.map(\.relativePath) == ["Music", "loose.txt", "shared.txt"])
        #expect(diffs.first?.enclosedItemCount == 1)
        #expect(diffs[1].enclosedItemCount == nil)
        #expect(diffs[2].enclosedItemCount == nil)
    }

    @Test func testCollapseRespectsComponentBoundaries() async throws {
        // "Music" is missing, and so is the separate folder "Music2". Its contents must
        // collapse under "Music2", not be swallowed by the "Music" prefix.
        let diffs = try diff(disk([.dir("/src/Music"), .dir("/src/Music2"), .file("/src/Music2/song.mp3")]))

        #expect(diffs.map(\.relativePath) == ["Music", "Music2"])
        #expect(diffs[0].enclosedItemCount == nil)
        #expect(diffs[1].enclosedItemCount == 1)
    }

    // MARK: - Case-insensitive matching
    // On the default macOS filesystem "Readme.txt" and "readme.txt" are the same file, but the
    // comparison maps are keyed by exact-case path. Without case-insensitive matching such a
    // pair reports as two phantom "missing" rows whose sync silently overwrites one side's
    // content. With `caseInsensitive: true` (both volumes case-insensitive) the pair must
    // become a single row carrying the real on-disk paths.

    @Test func testCaseVariantFilePairIsSingleRowWhenCaseInsensitive() async throws {
        let older = Date(timeIntervalSince1970: 5_000)
        let newer = older.addingTimeInterval(10)
        let diffs = try diff(disk([.file("/src/Readme.txt", date: newer, size: 100),
                                   .file("/dst/readme.txt", date: older, size: 200)]),
                             caseInsensitive: true)

        #expect(diffs.count == 1)
        #expect(diffs.first?.type == .differentDates)
        #expect(diffs.first?.action == .copyToRight)
        #expect(diffs.first?.description == "Source file is newer (names differ only by case)")
        // Both paths must be the real on-disk paths, not one side's casing projected onto the other.
        #expect(diffs.first?.leftItemPath == "/src/Readme.txt")
        #expect(diffs.first?.rightItemPath == "/dst/readme.txt")
        #expect(diffs.first?.leftFileSize == 100)
        #expect(diffs.first?.rightFileSize == 200)
    }

    @Test func testCaseVariantPairWithIdenticalMetadataStillSurfacesOneRow() async throws {
        // Same dates and sizes: the only difference is the on-disk casing. One row, and the
        // matching sizes keep it checksum-verifiable like any same-size pair.
        let now = Date(timeIntervalSince1970: 6_000)
        let diffs = try diff(disk([.file("/src/Readme.txt", date: now, size: 100),
                                   .file("/dst/readme.txt", date: now, size: 100)]),
                             caseInsensitive: true)

        #expect(diffs.count == 1)
        #expect(diffs.first?.type == .differentDates)
        #expect(diffs.first?.description == "Names differ only by case")
        #expect(diffs.first?.leftItemPath == "/src/Readme.txt")
        #expect(diffs.first?.rightItemPath == "/dst/readme.txt")
        #expect(diffs.first?.sizesMatch == true)
    }

    @Test func testCaseVariantFilePairStaysTwoRowsWhenCaseSensitive() async throws {
        // caseInsensitive=false (a case-sensitive volume in play): "Readme.txt" and
        // "readme.txt" can genuinely coexist, so they stay two rows.
        let now = Date(timeIntervalSince1970: 7_000)
        let diffs = try diff(disk([.file("/src/Readme.txt", date: now, size: 100),
                                   .file("/dst/readme.txt", date: now, size: 200)]),
                             caseInsensitive: false)

        #expect(diffs.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Readme.txt"]?.type == .missingOnRight)
        #expect(byPath["readme.txt"]?.type == .missingOnLeft)
    }

    @Test func testCaseVariantDirectoryPairComparesChildrenInstead() async throws {
        // Folders whose names differ only by case must match each other, so their children
        // compare pairwise instead of the whole subtree double-reporting as missing on both
        // sides. Identical children produce no rows; a changed child produces exactly one.
        let older = Date(timeIntervalSince1970: 8_000)
        let newer = older.addingTimeInterval(10)
        let diffs = try diff(disk([
            .dir("/src/Docs"), .dir("/dst/docs"),
            // Identical child: same name and metadata on both sides.
            .file("/src/Docs/same.txt", date: older, size: 50), .file("/dst/docs/same.txt", date: older, size: 50),
            // Changed child: left is newer.
            .file("/src/Docs/changed.txt", date: newer, size: 60), .file("/dst/docs/changed.txt", date: older, size: 60),
        ]), caseInsensitive: true)

        // Not: "Docs" missing on right + "docs" missing on left (each swallowing its children).
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Docs/changed.txt")
        #expect(diffs.first?.type == .differentDates)
        #expect(diffs.first?.action == .copyToRight)
        #expect(diffs.first?.leftItemPath == "/src/Docs/changed.txt")
        #expect(diffs.first?.rightItemPath == "/dst/docs/changed.txt")
    }

    /// Delegates to a `MockFileManager` but fails `attributesOfItem` for a chosen set of paths,
    /// simulating a permission-denied / placeholder-heavy subtree during a scan walk.
    private final class UnreadableAttributesFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        private let unreadablePaths: Set<String>

        init(inner: MockFileManager, unreadablePaths: Set<String>) {
            self.inner = inner
            self.unreadablePaths = unreadablePaths
        }

        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            if unreadablePaths.contains(path) {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try inner.attributesOfItem(atPath: path)
        }
        func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            try inner.setAttributes(attributes, ofItemAtPath: path)
        }
        func fileExists(atPath path: String) -> Bool { inner.fileExists(atPath: path) }
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
        func copyItem(at srcURL: URL, to dstURL: URL) throws { try inner.copyItem(at: srcURL, to: dstURL) }
        func moveItem(at srcURL: URL, to dstURL: URL) throws { try inner.moveItem(at: srcURL, to: dstURL) }
        func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func removeItem(at URL: URL) throws { try inner.removeItem(at: URL) }
        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
            try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        }
    }

    /// A walk over a subtree where thousands of entries are unreadable must not throw, must
    /// still return every readable entry, and collects the failures for one summary log line
    /// instead of one main-actor task per bad entry.
    @Test func testWalkWithManyUnreadableEntriesReturnsReadableOnesAndDoesNotThrow() throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)

        let attrs: [FileAttributeKey: Any] = [.modificationDate: Date(), .size: 10]
        var unreadable: Set<String> = []
        for i in 0..<2000 {
            let path = "/src/locked-\(i).dat"
            inner.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
            unreadable.insert(path)
        }
        inner.virtualDisk["/src/readable-a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
        inner.virtualDisk["/src/readable-b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)

        let fm = UnreadableAttributesFileManager(inner: inner, unreadablePaths: unreadable)
        let files = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: fm)

        #expect(files.count == 2)
        #expect(files["readable-a.txt"] != nil)
        #expect(files["readable-b.txt"] != nil)
    }

    /// A folder whose own attributes cannot be read is left out of the walk's map while what is
    /// inside it is still listed: the entry's read fails, and the enumerator descends regardless.
    /// The file inside must not pair across on its near-name into the right's `Swimming`, which
    /// pairs with nothing on the left and is reported missing: that would be a both-sides row
    /// inside a missing folder, and the folder's copy would carry the same `log.txt` again.
    @Test func aFileInAFolderTheWalkCouldNotReadDoesNotPairIntoAMissingFolder() throws {
        let now = Date()
        let inner = disk([.dir("/src/Swimming "), .dir("/dst/Swimming"),
                          .file("/src/Swimming /log.txt", date: now, size: 1),
                          .file("/dst/Swimming/log.txt", date: now, size: 2)])
        let fm = UnreadableAttributesFileManager(inner: inner, unreadablePaths: ["/src/Swimming "])

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: fm)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: inner)
        // The premise: the folder is gone from the map, the file inside it is not.
        #expect(Set(srcFiles.keys) == ["Swimming /log.txt"])

        let (srcProvider, dstProvider) = makeProviders()
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.map(\.relativePath) == ["Swimming", "Swimming /log.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: diffs.map { ($0.relativePath, $0) })
        #expect(byPath["Swimming"]?.type == .missingOnLeft)
        #expect(byPath["Swimming"]?.enclosedItemCount == 1)
        #expect(byPath["Swimming /log.txt"]?.type == .missingOnRight)
    }
}
