import Testing
import Foundation
@testable import Sync

/// Pins `FileSyncManager.validateItemName` (the one validator shared by the engine and the
/// rename/new-folder prompts) and that `renameItem`/`createFolder` reject bad names up front,
/// notably "../x", which `FileManager.moveItem` would resolve into the parent directory, silently
/// moving the file outside the visible pane.
@Suite struct ItemNameValidationTests {

    // MARK: - Validator

    /// Ordinary names, and dot-prefixed ones: only the literal "." / ".." traversal names are
    /// blocked.
    @Test(arguments: ["Foo", "name with spaces", "report (final) v2.txt", ".hidden", "..twodots"])
    func testAcceptsName(_ name: String) {
        #expect(FileSyncManager.validateItemName(name) == nil)
    }

    /// Empty and whitespace names, traversal names, and a separator, colon or NUL.
    @Test(arguments: ["", "   ", "\n", ".", "..", "../x", " .. ", "a/b", "/leading", "a:b", "a\0b"])
    func testRejectsName(_ name: String) {
        #expect(FileSyncManager.validateItemName(name) != nil)
    }

    @Test func testFailureReasonsAreHumanReadable() {
        #expect(FileSyncManager.validateItemName("a/b") == "Names can’t contain “/”.")
        #expect(FileSyncManager.validateItemName("a:b") == "Names can’t contain “:”.")
    }

    // MARK: - Engine defense

    @MainActor
    @Test func testRenameRejectsTraversalNameWithoutMoving() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let diskBefore = Set(mockFM.virtualDisk.keys)

        await manager.renameItem(at: "/src/report.txt", to: "../report.txt", fileManager: mockFM)

        #expect(manager.currentError?.title == "Rename Failed")
        #expect(manager.currentError?.message == "Names can’t contain “/”.")
        // Nothing moved anywhere — same entries, original still in place.
        #expect(Set(mockFM.virtualDisk.keys) == diskBefore)
    }

    @MainActor
    @Test func testCreateFolderRejectsBadNames() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let diskBefore = Set(mockFM.virtualDisk.keys)

        await manager.createFolder(named: "../escape", in: "/src", fileManager: mockFM)

        #expect(manager.currentError?.title == "Couldn’t Create Folder")
        #expect(Set(mockFM.virtualDisk.keys) == diskBefore)
    }
}
