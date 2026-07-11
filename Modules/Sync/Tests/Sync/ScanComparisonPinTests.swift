import Testing
import Foundation
@testable import Sync

/// Manager-level coverage for the executeScan comparison plumbing (FileSyncManager+Scanning) and
/// the FileDiffEngine directory walk on a real filesystem. The engine-level branch logic (date
/// tolerance, size fallback, type-mismatch directions) is pinned in FileDiffEngineTests; these
/// tests pin that a full manager scan surfaces each branch with the right type/action/paths, and
/// that hidden-file differences follow the showHiddenFiles toggle without a rescan.
@Suite struct ScanComparisonPinTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)

    private func fileStub(date: Date? = nil, size: Int? = nil) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [:]
        if let date { attrs[.modificationDate] = date }
        if let size { attrs[.size] = size }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs.isEmpty ? nil : attrs, contents: nil)
    }

    @MainActor
    @Test func testScanSurfacesEachComparisonBranchWithDirection() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)

        let base = Date(timeIntervalSince1970: 1_000_000)

        // One file per comparison branch of the scan loop.
        mockFM.virtualDisk["/left/left_only.txt"] = fileStub()
        mockFM.virtualDisk["/right/right_only.txt"] = fileStub()
        // Same date, different sizes.
        mockFM.virtualDisk["/left/size_mismatch.bin"] = fileStub(date: base, size: 100)
        mockFM.virtualDisk["/right/size_mismatch.bin"] = fileStub(date: base, size: 200)
        // Right newer by well over the 1s tolerance, same size.
        mockFM.virtualDisk["/left/right_newer.txt"] = fileStub(date: base, size: 50)
        mockFM.virtualDisk["/right/right_newer.txt"] = fileStub(date: base.addingTimeInterval(30), size: 50)
        // Dates differ by less than 1s, same size: inside tolerance, no difference.
        mockFM.virtualDisk["/left/close_date.txt"] = fileStub(date: base, size: 10)
        mockFM.virtualDisk["/right/close_date.txt"] = fileStub(date: base.addingTimeInterval(0.5), size: 10)
        // A folder present on both sides is not itself a difference.
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left/shared_dir"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right/shared_dir"), withIntermediateDirectories: true)

        let manager = FileSyncManager(fileManager: mockFM)
        await manager.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")

        let byPath = Dictionary(uniqueKeysWithValues: manager.differences.map { ($0.relativePath, $0) })
        #expect(manager.differences.count == 4)

        let leftOnly = try #require(byPath["left_only.txt"])
        #expect(leftOnly.type == .missingOnRight)
        #expect(leftOnly.action == .copyToRight)
        // The right path is the expected destination, derived even though nothing exists there.
        #expect(leftOnly.rightItemPath == "/right/left_only.txt")

        let rightOnly = try #require(byPath["right_only.txt"])
        #expect(rightOnly.type == .missingOnLeft)
        #expect(rightOnly.action == .copyToLeft)
        #expect(rightOnly.leftItemPath == "/left/right_only.txt")

        let sizeMismatch = try #require(byPath["size_mismatch.bin"])
        #expect(sizeMismatch.type == .differentDates)
        #expect(sizeMismatch.action == .copyToRight) // dates tie -> left is treated as truth
        #expect(sizeMismatch.leftFileSize == 100)
        #expect(sizeMismatch.rightFileSize == 200)

        let rightNewer = try #require(byPath["right_newer.txt"])
        #expect(rightNewer.type == .differentDates)
        #expect(rightNewer.action == .copyToLeft)

        #expect(byPath["close_date.txt"] == nil)
        #expect(byPath["shared_dir"] == nil)
        #expect(manager.hasScanned)
        #expect(!manager.isScanning)
    }

    @MainActor
    @Test func testHiddenFileDifferenceFollowsShowHiddenToggleWithoutRescan() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/left/.secret"] = fileStub()
        mockFM.virtualDisk["/left/visible.txt"] = fileStub()

        let manager = FileSyncManager(fileManager: mockFM)
        await manager.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")

        // Default: the hidden difference is filtered out of the published list.
        #expect(manager.differences.map(\.relativePath) == ["visible.txt"])

        // The raw scan kept it: toggling the setting reveals it with no new scan.
        // The didSet's filter pass is fire-and-forget; await one explicitly for a
        // deterministic read (whichever pass publishes computes identical state).
        manager.showHiddenFiles = true
        await manager.applyFilters()
        #expect(Set(manager.differences.map(\.relativePath)) == [".secret", "visible.txt"])
    }

    /// FileDiffEngineTests drive getFilesInDirectory through MockFileManager (the attributes
    /// path); this pins the real-FileManager resourceValues path: recursion into nested subdirs,
    /// root-relative keys, directory flags, sizes, mod dates, and hidden files.
    @Test func testGetFilesInDirectoryOnRealFilesystem() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DiffEngineRealFS-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        // Canonicalize the root: /var/... is a symlink to /private/var/..., the real enumerator
        // yields canonical URLs, and the engine trims relative keys with a plain basePath prefix
        // check — an uncanonical root would defeat it and every key would come back near-absolute.
        // (resolvingSymlinksInPath can't be used here: it deliberately strips /private.)
        let canonicalPath = try #require(tempRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let root = URL(fileURLWithPath: canonicalPath)
        let nested = root.appendingPathComponent("nested/sub")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        try Data("hello".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data("deep contents".utf8).write(to: nested.appendingPathComponent("deep.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden"))

        let knownDate = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: knownDate], ofItemAtPath: root.appendingPathComponent("top.txt").path)

        let files = try FileDiffEngine.getFilesInDirectory(root)

        // Every file and directory keyed by root-relative path; the root itself excluded.
        #expect(Set(files.keys) == ["top.txt", ".hidden", "nested", "nested/sub", "nested/sub/deep.txt"])
        #expect(files["nested"]?.isDirectory == true)
        #expect(files["nested/sub"]?.isDirectory == true)
        #expect(files["nested/sub/deep.txt"]?.isDirectory == false)
        #expect(files["nested/sub/deep.txt"]?.fileSize == "deep contents".utf8.count)
        let topDate = try #require(files["top.txt"]?.modificationDate)
        #expect(abs(topDate.timeIntervalSince(knownDate)) < 1)
    }

    /// Regression: a scan rooted at an uncanonical symlinked path (temporaryDirectory lives under
    /// /var/..., a symlink to /private/var/...) must still key files by root-relative path. The
    /// real enumerator yields canonical URLs, so trimming with a plain prefix check against the
    /// uncanonical root left every key near-absolute and both panes falsely diffed as missing.
    @Test func testGetFilesInDirectoryWithUncanonicalSymlinkedRoot() async throws {
        let fm = FileManager.default
        // Deliberately NOT canonicalized, unlike the test above.
        let root = fm.temporaryDirectory.appendingPathComponent("DiffEngineSymlinkRoot-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Precondition: the root really is behind a symlink; a canonical temp dir would make
        // this test vacuously pass.
        let canonicalPath = try #require(root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        try #require(canonicalPath != root.path)

        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("top.txt"))
        try Data("deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))

        // A second uncanonical root with identical content and dates, for the diff pin below.
        let otherRoot = fm.temporaryDirectory.appendingPathComponent("DiffEngineSymlinkRoot-\(UUID().uuidString)")
        try fm.createDirectory(at: otherRoot.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: otherRoot) }
        try Data("hello".utf8).write(to: otherRoot.appendingPathComponent("top.txt"))
        try Data("deep".utf8).write(to: otherRoot.appendingPathComponent("nested/deep.txt"))
        for name in ["top.txt", "nested/deep.txt"] {
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(name).path)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: otherRoot.appendingPathComponent(name).path)
        }

        let files = try FileDiffEngine.getFilesInDirectory(root)
        #expect(Set(files.keys) == ["top.txt", "nested", "nested/deep.txt"])

        // Symptom-level pin: identical content under a second uncanonical root must produce
        // zero differences (the bug made everything missing on both sides).
        let otherFiles = try FileDiffEngine.getFilesInDirectory(otherRoot)
        let diffs = FileDiffEngine.computeDifferences(
            left: Self.left, leftURL: root,
            right: Self.right, rightURL: otherRoot,
            leftFilesInfo: files, rightFilesInfo: otherFiles
        )
        #expect(diffs.isEmpty)
    }

    /// Regression: the two scan sources classified symlinks differently — the tree path carried
    /// the LINK's own size/mtime for symlinked files, and the disk walk excluded symlinks
    /// entirely — so the same disk state produced different rows depending on which branch ran.
    /// Both paths must report symlinked files with the TARGET's size/date. (One divergence
    /// remains and is pinned below: only the tree path walks a symlinked directory's contents.)
    @Test func testSymlinkedFilesReportTargetMetadataInBothScanPaths() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("DiffEngineSymlinks-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        // Canonical root: both paths key by root-relative path against canonical child URLs.
        let canonicalPath = try #require(tempRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let root = URL(fileURLWithPath: canonicalPath)

        let content = "twenty-six bytes of stuff!"
        let knownDate = Date(timeIntervalSince1970: 1_600_000_000)
        try Data(content.utf8).write(to: root.appendingPathComponent("target.txt"))
        try fm.setAttributes([.modificationDate: knownDate], ofItemAtPath: root.appendingPathComponent("target.txt").path)
        // The link itself has a different mtime (now) and size (the path string's length).
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("target.txt"))
        let dir = root.appendingPathComponent("dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("inner.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("dlink"), withDestinationURL: dir)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("gone.txt"))

        // Disk-walk path: the symlinked file participates, with the target's metadata.
        let walk = try FileDiffEngine.getFilesInDirectory(root)
        let walkedLink = try #require(walk["link.txt"])
        #expect(!walkedLink.isDirectory)
        #expect(walkedLink.fileSize == content.utf8.count)
        let walkedDate = try #require(walkedLink.modificationDate)
        #expect(abs(walkedDate.timeIntervalSince(knownDate)) < 1)
        // The symlinked directory is reported as a directory; broken links are dropped.
        #expect(walk["dlink"]?.isDirectory == true)
        #expect(walk["broken"] == nil)
        // Pinned divergence: the enumerator does not walk INTO symlinked directories —
        // their contents participate only via the tree path.
        #expect(walk["dlink/inner.txt"] == nil)

        // Tree path: same target metadata for the symlinked file, and linked dirs walked.
        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        let derived = FileDiffEngine.filesInfo(fromTree: tree, basePath: root.path)
        let treeLink = try #require(derived["link.txt"])
        #expect(treeLink.fileSize == content.utf8.count)
        let treeDate = try #require(treeLink.modificationDate)
        #expect(abs(treeDate.timeIntervalSince(knownDate)) < 1)
        #expect(derived["broken"] == nil)
        #expect(derived["dlink/inner.txt"] != nil)
    }
}
