import Testing
import Foundation
@testable import Sync

/// Direct coverage for two FileOperations helpers: `generateUniqueURL` (keep-both numbering) and
/// `ensureParentDirectoryExists` (the cloud placeholder guard). Both are pure functions over
/// `FileManaging`, so the mock disk suffices.
@Suite struct FileOperationsHelperTests {

    // MARK: generateUniqueURL

    /// Keep-both numbering:
    /// - it increments past existing numbered copies;
    /// - with no extension, " 2" is appended without a trailing dot;
    /// - only the last path extension is split off, so the numbering lands before ".gz";
    /// - a free name comes back unchanged.
    @Test(arguments: [
        (["report.pdf", "report 2.pdf", "report 3.pdf"], "report.pdf", "/dst/report 4.pdf"),
        (["README"], "README", "/dst/README 2"),
        (["archive.tar.gz"], "archive.tar.gz", "/dst/archive.tar 2.gz"),
        ([], "fresh.txt", "/dst/fresh.txt"),
    ])
    func testGenerateUniqueURL(existing: [String], input: String, expected: String) throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in existing {
            mockFM.virtualDisk["/dst/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }

        let unique = FileSyncManager.generateUniqueURL(for: URL(fileURLWithPath: "/dst/\(input)"), fileManager: mockFM)
        #expect(unique.path == expected)
    }

    // MARK: ensureParentDirectoryExists

    @Test func testEnsureParentThrowsWhenParentIsAFile() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Cloud placeholder: the package folder arrived as a plain file.
        mockFM.virtualDisk["/dst/pkg"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        #expect(throws: FileSyncManager.FileOperationError.parentExistsAsFile(parentName: "pkg")) {
            try FileSyncManager.ensureParentDirectoryExists(
                for: URL(fileURLWithPath: "/dst/pkg/Previews"), fileManager: mockFM)
        }
    }

    @Test func testEnsureParentCreatesMissingParent() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        try FileSyncManager.ensureParentDirectoryExists(
            for: URL(fileURLWithPath: "/dst/newdir/child.txt"), fileManager: mockFM)

        var isDir: ObjCBool = false
        #expect(mockFM.fileExists(atPath: "/dst/newdir", isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func testEnsureParentIsNoOpWhenParentIsDirectory() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/existing"), withIntermediateDirectories: true)

        // Already a directory -> must not throw and must not disturb it.
        try FileSyncManager.ensureParentDirectoryExists(
            for: URL(fileURLWithPath: "/dst/existing/child.txt"), fileManager: mockFM)
        #expect(mockFM.fileExists(atPath: "/dst/existing"))
    }
}
