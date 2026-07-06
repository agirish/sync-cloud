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
        manager.showHiddenFiles = true
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
}
