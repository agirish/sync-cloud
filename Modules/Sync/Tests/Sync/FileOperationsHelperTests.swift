import Testing
import Foundation
@testable import Sync

/// Unit coverage for the two FileOperations helpers that only had indirect coverage:
/// `generateUniqueURL` (keep-both numbering) and `ensureParentDirectoryExists` (the cloud
/// placeholder guard). Both are pure functions over `FileManaging`, so the mock disk suffices.
@Suite struct FileOperationsHelperTests {

    // MARK: generateUniqueURL

    @Test func testGenerateUniqueURLIncrementsPastExistingNumbered() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report 2.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report 3.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let unique = FileSyncManager.generateUniqueURL(for: URL(fileURLWithPath: "/dst/report.pdf"), fileManager: mockFM)
        #expect(unique.path == "/dst/report 4.pdf")
    }

    @Test func testGenerateUniqueURLExtensionlessFile() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/README"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // No extension -> " 2" is appended without a trailing dot.
        let unique = FileSyncManager.generateUniqueURL(for: URL(fileURLWithPath: "/dst/README"), fileManager: mockFM)
        #expect(unique.path == "/dst/README 2")
    }

    @Test func testGenerateUniqueURLPreservesFinalExtensionOnly() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/archive.tar.gz"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // Only the last path extension is split off; the numbering lands before ".gz".
        let unique = FileSyncManager.generateUniqueURL(for: URL(fileURLWithPath: "/dst/archive.tar.gz"), fileManager: mockFM)
        #expect(unique.path == "/dst/archive.tar 2.gz")
    }

    @Test func testGenerateUniqueURLReturnsInputWhenFree() throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let target = URL(fileURLWithPath: "/dst/fresh.txt")
        #expect(FileSyncManager.generateUniqueURL(for: target, fileManager: mockFM).path == target.path)
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
