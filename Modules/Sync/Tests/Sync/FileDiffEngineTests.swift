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

    @Test func testSameFilesNoDifferences() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        let attributes: [FileAttributeKey: Any] = [
            .modificationDate: now,
            .size: 1024
        ]
        
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attributes, contents: nil)
        mockFM.virtualDisk["/dst/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attributes, contents: nil)
        
        let srcProvider = CloudProvider(id: UUID().uuidString, displayName: "Local Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: UUID().uuidString, displayName: "Local Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
        
        #expect(diffs.isEmpty)
    }
    
    @Test func testDateTolerance() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        let almostNow = now.addingTimeInterval(0.5) // Less than 1 second diff
        let veryDifferent = now.addingTimeInterval(5.0) // More than 1 second diff
        
        let attrSrc: [FileAttributeKey: Any] = [.modificationDate: now, .size: 1024]
        let attrDstClose: [FileAttributeKey: Any] = [.modificationDate: almostNow, .size: 1024]
        let attrDstFar: [FileAttributeKey: Any] = [.modificationDate: veryDifferent, .size: 1024]
        
        mockFM.virtualDisk["/src/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDstClose, contents: nil)
        
        mockFM.virtualDisk["/src/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDstFar, contents: nil)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
        
        // Only file2.txt should have a difference because its date diff is > 1s
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "file2.txt")
        #expect(diffs.first?.type == .differentDates)
    }
    
    @Test func testSizeDiscrepancy() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let now = Date()
        
        let attrSrc: [FileAttributeKey: Any] = [.modificationDate: now, .size: 1024]
        let attrDst: [FileAttributeKey: Any] = [.modificationDate: now, .size: 2048]
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrc, contents: nil)
        mockFM.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDst, contents: nil)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
        
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "data.bin")
        #expect(diffs.first?.type == .differentDates) // Current engine labels size diffs under the "differentDates/size" generic catch-all
    }

    @Test func testMissingFilesCarryTheirExistingSideSize() async throws {
        // A file that exists on only one side must still report its size, so the Differences
        // list can show it instead of "—". A missing folder has no byte size and stays nil.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let now = Date()
        mockFM.virtualDisk["/src/only-left.txt"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.modificationDate: now, .size: 4096], contents: nil)
        mockFM.virtualDisk["/dst/only-right.txt"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.modificationDate: now, .size: 8192], contents: nil)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/folderOnly"), withIntermediateDirectories: true)

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)

        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
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

    @Test func testTypeMismatchPrefersNewerDestination() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = older.addingTimeInterval(10)

        mockFM.virtualDisk["/src/mismatch"] = MockFileManager.FileStub(
            isDirectory: false,
            attributes: [.modificationDate: older],
            contents: nil
        )
        mockFM.virtualDisk["/dst/mismatch"] = MockFileManager.FileStub(
            isDirectory: true,
            attributes: [.modificationDate: newer],
            contents: []
        )

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)

        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "mismatch")
        #expect(diffs.first?.action == .copyToLeft)
        #expect(diffs.first?.description == "Dest item is newer (type mismatch)")
    }

    @Test func testTypeMismatchDefaultsToFolderWhenDatesTie() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/mismatch"] = MockFileManager.FileStub(
            isDirectory: true,
            attributes: nil,
            contents: []
        )
        mockFM.virtualDisk["/dst/mismatch"] = MockFileManager.FileStub(
            isDirectory: false,
            attributes: nil,
            contents: nil
        )

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)

        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "mismatch")
        #expect(diffs.first?.action == .copyToRight)
        #expect(diffs.first?.description == "Type mismatch; defaulting to the folder from Source")
    }
    
    @Test func testEmptyDirectorySync() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        // Create an empty directory in source
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/empty_folder"), withIntermediateDirectories: true)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        // Verify the empty folder is found by scan
        #expect(srcFiles["empty_folder"] != nil)
        #expect(srcFiles["empty_folder"]?.isDirectory == true)
        
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
        
        // Should find 1 difference (the missing directory)
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "empty_folder")
        #expect(diffs.first?.action == .copyToRight)
    }
    
    @Test func testMissingModificationDateFallback() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        // Simulating POSIX attributes or system aliases where modificationDate is missing (nil)
        let attrSrcSize500: [FileAttributeKey: Any] = [.size: 500] // No date
        let attrDstSize1000: [FileAttributeKey: Any] = [.size: 1000] // No date
        
        mockFM.virtualDisk["/src/nometa.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrSrcSize500, contents: nil)
        mockFM.virtualDisk["/dst/nometa.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: attrDstSize1000, contents: nil)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        
        // Test that despite missing dates, the size discrepancy forces a sync
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles
        )
        
        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "nometa.txt")
        #expect(diffs.first?.description == "Sizes differ")
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
    // Existing tests assert one direction of the type-mismatch branch and count/type of the same-type
    // date branch; these pin the *opposite* directions so a sign-flip (syncing the wrong way, which
    // would overwrite newer data with older) can't pass silently.

    @Test func testTypeMismatchPrefersNewerSource() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = older.addingTimeInterval(10)
        // Left is the newer side of the mismatch (a file), right is an older directory.
        mockFM.virtualDisk["/src/mismatch"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer], contents: nil)
        mockFM.virtualDisk["/dst/mismatch"] = MockFileManager.FileStub(isDirectory: true, attributes: [.modificationDate: older], contents: [])

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.action == .copyToRight)
        #expect(diffs.first?.description == "Source item is newer (type mismatch)")
    }

    @Test func testSameTypeRightNewerCopiesToLeft() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 2_000)
        let newer = older.addingTimeInterval(10)
        // Same type (both files), same size, right is newer -> pull the newer right onto the left.
        mockFM.virtualDisk["/src/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 100], contents: nil)
        mockFM.virtualDisk["/dst/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer, .size: 100], contents: nil)

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.action == .copyToLeft)
        #expect(diffs.first?.description == "Dest file is newer")
    }

    @Test func testSameTypeLeftNewerCopiesToRight() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 3_000)
        let newer = older.addingTimeInterval(10)
        mockFM.virtualDisk["/src/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer, .size: 100], contents: nil)
        mockFM.virtualDisk["/dst/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 100], contents: nil)

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)

        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.action == .copyToRight)
        #expect(diffs.first?.description == "Source file is newer")
    }

    // MARK: - Missing-folder collapse
    // A folder missing on one side is synced with a single recursive copy, so its contents
    // must not appear as separate differences: they'd double-copy during bulk sync and leave
    // stale rows (with spurious overwrite prompts) after the folder entry is synced.

    private func makeProviders() -> (CloudProvider, CloudProvider) {
        (CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud),
         CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud))
    }

    @Test func testMissingFolderCollapsesContentsIntoSingleEntry() async throws {
        let mockFM = MockFileManager()
        // The mock's createDirectory only registers the leaf, so create each level explicitly.
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Music"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Music/Inner"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Music/a.mp3"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Music/b.mp3"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Music/Inner/c.mp3"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Music")
        #expect(diffs.first?.type == .missingOnRight)
        #expect(diffs.first?.action == .copyToRight)
        // 4 collapsed items: a.mp3, b.mp3, Inner, Inner/c.mp3
        #expect(diffs.first?.enclosedItemCount == 4)
    }

    @Test func testMissingFolderCollapseOnLeftSide() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/Photos"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/dst/Photos/p1.jpg"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Photos")
        #expect(diffs.first?.type == .missingOnLeft)
        #expect(diffs.first?.action == .copyToLeft)
        #expect(diffs.first?.enclosedItemCount == 1)
    }

    @Test func testCollapseKeepsUnrelatedDifferences() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Music"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Music/a.mp3"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // A sibling file missing on right — not inside the missing folder, must survive.
        mockFM.virtualDisk["/src/loose.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // A changed file present on both sides must survive too.
        let now = Date()
        mockFM.virtualDisk["/src/shared.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now.addingTimeInterval(10), .size: 10], contents: nil)
        mockFM.virtualDisk["/dst/shared.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now, .size: 10], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.map(\.relativePath) == ["Music", "loose.txt", "shared.txt"])
        #expect(diffs.first?.enclosedItemCount == 1)
        #expect(diffs[1].enclosedItemCount == nil)
        #expect(diffs[2].enclosedItemCount == nil)
    }

    @Test func testCollapseRespectsComponentBoundaries() async throws {
        let mockFM = MockFileManager()
        // "Music" is missing, and so is the separate folder "Music2". Its contents must
        // collapse under "Music2", not be swallowed by the "Music" prefix.
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Music"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Music2"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Music2/song.mp3"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.map(\.relativePath) == ["Music", "Music2"])
        #expect(diffs[0].enclosedItemCount == nil)
        #expect(diffs[1].enclosedItemCount == 1)
    }

    // MARK: - Type-mismatch folder collapse
    // A folder that pairs with a FILE on the other side resolves with a single action on its
    // row (dir wins: recursive copy; file wins: the subtree is replaced wholesale). Its
    // descendants must therefore collapse into that row like a missing folder's do — separate
    // child rows double-copy after a dir-wins sync, race the parent's replace op in parallel
    // bulk sync, and go stale after a file-wins sync.

    @Test func testTypeMismatchFolderCollapsesDirSideChildren() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Bundle"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // Directory on the left with two children; a plain file at the same path on the right.
        mockFM.virtualDisk["/src/Bundle/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Bundle/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/Bundle"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Bundle")
        #expect(diffs.first?.type == .differentDates)
        #expect(diffs.first?.action == .copyToRight) // dates tie -> folder side wins
        #expect(diffs.first?.enclosedItemCount == 2)
    }

    @Test func testTypeMismatchFolderStillCollapsesWhenFileWins() async throws {
        // The file side being newer flips the action to copyToLeft, but the dir side's
        // children must still fold into the single row — they'd otherwise point at paths
        // the winning file is about to replace.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 10_000)
        let newer = older.addingTimeInterval(10)
        mockFM.virtualDisk["/src/Bundle"] = MockFileManager.FileStub(isDirectory: true, attributes: [.modificationDate: older], contents: [])
        mockFM.virtualDisk["/src/Bundle/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Bundle/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/Bundle"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Bundle")
        #expect(diffs.first?.action == .copyToLeft)
        #expect(diffs.first?.description == "Dest item is newer (type mismatch)")
        #expect(diffs.first?.enclosedItemCount == 2)
    }

    @Test func testTypeMismatchFolderOnRightCollapsesItsChildren() async throws {
        // Mirror direction: the directory is on the RIGHT, so its children surface as
        // missingOnLeft rows — they must collapse into the mismatch row all the same.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/Bundle"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Bundle"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/Bundle/p.jpg"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/Bundle/q.jpg"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Bundle")
        #expect(diffs.first?.action == .copyToLeft) // dates tie -> folder side wins
        #expect(diffs.first?.enclosedItemCount == 2)
    }

    @Test func testMissingDirInsideTypeMismatchFolderCollapsesFully() async throws {
        // A nested directory inside the type-mismatch dir is itself a missing-on-right dir;
        // it and its contents must all roll up into the top-most (type-mismatch) row instead
        // of surviving as a partially-collapsed subtree.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Bundle"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Bundle/Sub"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Bundle/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/Bundle/Sub/deep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/Bundle"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Bundle")
        // 3 collapsed items: a.txt, Sub, Sub/deep.txt
        #expect(diffs.first?.enclosedItemCount == 3)
    }

    @Test func testCaseVariantTypeMismatchFolderCollapses() async throws {
        // Case-insensitive matching pairs left file "Report" with right dir "report"; the row
        // carries the LEFT relativePath while the dir's children carry the right-side casing.
        // The children must still fold into the mismatch row, not survive as missingOnLeft rows.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/report"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/Report"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report/x.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report/y.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles,
            caseInsensitive: true)

        #expect(diffs.count == 1)
        #expect(diffs.first?.relativePath == "Report")
        #expect(diffs.first?.type == .differentDates)
        #expect(diffs.first?.action == .copyToLeft) // dates tie -> folder side wins
        #expect(diffs.first?.leftItemPath == "/src/Report")
        #expect(diffs.first?.rightItemPath == "/dst/report")
        #expect(diffs.first?.enclosedItemCount == 2)
    }

    // MARK: - Case-insensitive matching
    // On the default macOS filesystem "Readme.txt" and "readme.txt" are the same file, but the
    // comparison maps are keyed by exact-case path. Without case-insensitive matching such a
    // pair reports as two phantom "missing" rows whose sync silently overwrites one side's
    // content. With `caseInsensitive: true` (both volumes case-insensitive) the pair must
    // become a single row carrying the real on-disk paths.

    @Test func testCaseVariantFilePairIsSingleRowWhenCaseInsensitive() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 5_000)
        let newer = older.addingTimeInterval(10)
        mockFM.virtualDisk["/src/Readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer, .size: 100], contents: nil)
        mockFM.virtualDisk["/dst/readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 200], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles,
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
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 6_000)
        mockFM.virtualDisk["/src/Readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now, .size: 100], contents: nil)
        mockFM.virtualDisk["/dst/readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now, .size: 100], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles,
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
        // "readme.txt" can genuinely coexist, so the old two-row behavior must hold.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 7_000)
        mockFM.virtualDisk["/src/Readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now, .size: 100], contents: nil)
        mockFM.virtualDisk["/dst/readme.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now, .size: 200], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles,
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
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Docs"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/docs"), withIntermediateDirectories: true)

        let older = Date(timeIntervalSince1970: 8_000)
        let newer = older.addingTimeInterval(10)
        // Identical child: same name and metadata on both sides.
        mockFM.virtualDisk["/src/Docs/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 50], contents: nil)
        mockFM.virtualDisk["/dst/docs/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 50], contents: nil)
        // Changed child: left is newer.
        mockFM.virtualDisk["/src/Docs/changed.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: newer, .size: 60], contents: nil)
        mockFM.virtualDisk["/dst/docs/changed.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: older, .size: 60], contents: nil)

        let (srcProvider, dstProvider) = makeProviders()
        let srcFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        let dstFiles = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/dst"), fileManager: mockFM)
        let diffs = FileDiffEngine.computeDifferences(
            left: srcProvider, leftURL: URL(fileURLWithPath: "/src"),
            right: dstProvider, rightURL: URL(fileURLWithPath: "/dst"),
            leftFilesInfo: srcFiles, rightFilesInfo: dstFiles,
            caseInsensitive: true)

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
    /// still return every readable entry, and (per the aggregated-logging fix) collects the
    /// failures for one summary log line instead of one MainActor task per bad entry.
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
}
