import Testing
import Foundation
@testable import Sync

/// Pins `FileSyncManager.validateItemName` (the single validator shared by the engine and the
/// rename/new-folder prompts) and that `renameItem`/`createFolder` reject bad names up front —
/// notably "../x", which `FileManager.moveItem` would otherwise resolve into the parent
/// directory and silently relocate the file outside the visible pane.
@Suite struct ItemNameValidationTests {

    // MARK: - Validator

    @Test func testAcceptsOrdinaryNames() {
        #expect(FileSyncManager.validateItemName("Foo") == nil)
        #expect(FileSyncManager.validateItemName("name with spaces") == nil)
        #expect(FileSyncManager.validateItemName("report (final) v2.txt") == nil)
    }

    @Test func testAcceptsHiddenFileNames() {
        // Only the literal "." / ".." traversal names are blocked, not dot-prefixed names.
        #expect(FileSyncManager.validateItemName(".hidden") == nil)
        #expect(FileSyncManager.validateItemName("..twodots") == nil)
    }

    @Test func testRejectsEmptyAndWhitespaceNames() {
        #expect(FileSyncManager.validateItemName("") != nil)
        #expect(FileSyncManager.validateItemName("   ") != nil)
        #expect(FileSyncManager.validateItemName("\n") != nil)
    }

    @Test func testRejectsTraversalNames() {
        #expect(FileSyncManager.validateItemName(".") != nil)
        #expect(FileSyncManager.validateItemName("..") != nil)
        #expect(FileSyncManager.validateItemName("../x") != nil)
        #expect(FileSyncManager.validateItemName(" .. ") != nil)
    }

    @Test func testRejectsSeparatorAndColonAndNul() {
        #expect(FileSyncManager.validateItemName("a/b") != nil)
        #expect(FileSyncManager.validateItemName("/leading") != nil)
        #expect(FileSyncManager.validateItemName("a:b") != nil)
        #expect(FileSyncManager.validateItemName("a\0b") != nil)
    }

    @Test func testFailureReasonsAreHumanReadable() {
        #expect(FileSyncManager.validateItemName("a/b") == "Names can't contain \"/\".")
        #expect(FileSyncManager.validateItemName("a:b") == "Names can't contain \":\".")
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
        #expect(manager.currentError?.message == "Names can't contain \"/\".")
        // Nothing moved anywhere — same entries, original still in place.
        #expect(Set(mockFM.virtualDisk.keys) == diskBefore)
    }

    @MainActor
    @Test func testRenameRejectsSlashName() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.renameItem(at: "/src/report.txt", to: "a/b", fileManager: mockFM)

        #expect(manager.currentError != nil)
        #expect(mockFM.virtualDisk["/src/report.txt"] != nil)
    }

    @MainActor
    @Test func testCreateFolderRejectsBadNames() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        let diskBefore = Set(mockFM.virtualDisk.keys)

        await manager.createFolder(named: "../escape", in: "/src", fileManager: mockFM)

        #expect(manager.currentError?.title == "Couldn't Create Folder")
        #expect(Set(mockFM.virtualDisk.keys) == diskBefore)
    }
}
