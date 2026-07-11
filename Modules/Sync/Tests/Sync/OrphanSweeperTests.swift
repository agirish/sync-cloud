import Foundation
import Testing
@testable import Sync

/// Pins the safety gates of the orphaned-working-file sweep: only exact `.tmp_<UUID>`
/// artifacts older than the age threshold are reaped; `.rollback_<UUID>` replacement
/// backups (potentially the only copy of a replaced file, see c945e30) and user files
/// that merely look similar are never touched.
@Suite struct OrphanSweeperTests {

    private let anHourAndABit: TimeInterval = OrphanSweeper.minimumAge + 60

    private func node(_ name: String, in dir: String = "/root", age: TimeInterval?, isDirectory: Bool = false, children: [FileNode]? = nil) -> FileNode {
        FileNode(
            id: dir + "/" + name,
            name: name,
            isDirectory: isDirectory,
            children: children,
            modificationDate: age.map { Date().addingTimeInterval(-$0) }
        )
    }

    // MARK: - Name pattern

    @Test func testTempArtifactNameRequiresExactUUIDSuffix() {
        #expect(OrphanSweeper.isTempArtifactName(".tmp_\(UUID().uuidString)"))
        // Lowercase round-trips through UUID(uuidString:) too — still the same artifact.
        #expect(OrphanSweeper.isTempArtifactName(".tmp_\(UUID().uuidString.lowercased())"))

        #expect(!OrphanSweeper.isTempArtifactName(".tmp_notes.txt"))
        #expect(!OrphanSweeper.isTempArtifactName(".tmp_"))
        #expect(!OrphanSweeper.isTempArtifactName(".tmp_1234"))
        #expect(!OrphanSweeper.isTempArtifactName(".tmp_\(UUID().uuidString)x"))
        #expect(!OrphanSweeper.isTempArtifactName("tmp_\(UUID().uuidString)"))
        #expect(!OrphanSweeper.isTempArtifactName(".rollback_\(UUID().uuidString)"))
    }

    // MARK: - Candidate selection from pane trees

    @Test func testOldTempArtifactIsACandidate() {
        let tmp = node(".tmp_\(UUID().uuidString)", age: anHourAndABit)
        let scan = OrphanSweeper.findArtifacts(inTrees: [[tmp]], olderThan: Date().addingTimeInterval(-OrphanSweeper.minimumAge))
        #expect(scan.tempPaths == [tmp.id])
    }

    @Test func testRecentTempArtifactIsKept() {
        let tmp = node(".tmp_\(UUID().uuidString)", age: 60)
        let scan = OrphanSweeper.findArtifacts(inTrees: [[tmp]], olderThan: Date().addingTimeInterval(-OrphanSweeper.minimumAge))
        #expect(scan.tempPaths.isEmpty)
    }

    @Test func testUnknownModificationDateIsKept() {
        // Deleting needs proof of age; a node with no date (e.g. mock-built trees) stays.
        let tmp = node(".tmp_\(UUID().uuidString)", age: nil)
        let scan = OrphanSweeper.findArtifacts(inTrees: [[tmp]], olderThan: .distantFuture)
        #expect(scan.tempPaths.isEmpty)
    }

    @Test func testRollbackBackupsAreNeverCandidatesRegardlessOfAge() {
        let backup = node(".rollback_\(UUID().uuidString)", age: anHourAndABit * 1000)
        let scan = OrphanSweeper.findArtifacts(inTrees: [[backup]], olderThan: .distantFuture)
        #expect(scan.tempPaths.isEmpty)
        #expect(scan.rollbackCount == 1)
    }

    @Test func testUserFileWithNonUUIDTmpPrefixIsKept() {
        let userFile = node(".tmp_notes.txt", age: anHourAndABit * 1000)
        let scan = OrphanSweeper.findArtifacts(inTrees: [[userFile]], olderThan: .distantFuture)
        #expect(scan.tempPaths.isEmpty)
    }

    @Test func testNestedArtifactsAreFoundAndDuplicatesAcrossTreesCollapse() {
        let tmp = node(".tmp_\(UUID().uuidString)", in: "/root/sub", age: anHourAndABit)
        let sub = node("sub", age: nil, isDirectory: true, children: [tmp])
        // Both panes showing the same folder must not list the artifact twice.
        let scan = OrphanSweeper.findArtifacts(inTrees: [[sub], [sub]], olderThan: Date().addingTimeInterval(-OrphanSweeper.minimumAge))
        #expect(scan.tempPaths == [tmp.id])
    }

    @Test func testTempDirectoryIsSweptWholeWithoutDescendingIntoIt() {
        let dirName = ".tmp_\(UUID().uuidString)"
        let child = node("partial.bin", in: "/root/" + dirName, age: anHourAndABit)
        let tmpDir = node(dirName, age: anHourAndABit, isDirectory: true, children: [child])
        let scan = OrphanSweeper.findArtifacts(inTrees: [[tmpDir]], olderThan: Date().addingTimeInterval(-OrphanSweeper.minimumAge))
        // The directory itself, not its contents — removing it takes the children along.
        #expect(scan.tempPaths == [tmpDir.id])
    }

    // MARK: - Removal

    @Test func testRemoveRefusesPathsThatAreNotTempArtifacts() {
        let fm = MockFileManager()
        let rollback = "/root/.rollback_\(UUID().uuidString)"
        let userFile = "/root/document.txt"
        fm.virtualDisk[rollback] = .init(isDirectory: false, attributes: nil, contents: nil)
        fm.virtualDisk[userFile] = .init(isDirectory: false, attributes: nil, contents: nil)

        // Defense in depth: even if such paths were handed in, they are not deleted.
        let removed = OrphanSweeper.removeTempArtifacts(atPaths: [rollback, userFile], fileManager: fm)

        #expect(removed == 0)
        #expect(fm.virtualDisk[rollback] != nil)
        #expect(fm.virtualDisk[userFile] != nil)
        #expect(fm.trashedPaths.isEmpty)
        #expect(fm.attemptedRemovePaths.isEmpty)
    }

    @Test func testRemoveFallsBackToRemoveItemOnTrashlessVolumes() {
        let fm = MockFileManager()
        fm.shouldFailTrash = true
        let tmp = "/root/.tmp_\(UUID().uuidString)"
        fm.virtualDisk[tmp] = .init(isDirectory: false, attributes: nil, contents: nil)

        let removed = OrphanSweeper.removeTempArtifacts(atPaths: [tmp], fileManager: fm)

        #expect(removed == 1)
        #expect(fm.virtualDisk[tmp] == nil)
    }

    // MARK: - End to end on a real temp directory (the production data path:
    // buildTree-provided metadata drives candidate selection, then removal).

    @Test func testSweepRemovesOnlyOldTempArtifactsOnDisk() async throws {
        let fm = FileManager.default
        // Canonical root (see makeCanonicalTempRoot) so the paths the walk reports match
        // the expectations below.
        let root = try makeCanonicalTempRoot(prefix: "OrphanSweeperTests")
        defer { try? fm.removeItem(at: root) }

        let oldDate = Date().addingTimeInterval(-anHourAndABit)
        func makeFile(_ name: String, old: Bool) throws -> URL {
            let url = root.appendingPathComponent(name)
            try "partial".write(to: url, atomically: true, encoding: .utf8)
            if old {
                try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            }
            return url
        }

        let oldTmp = try makeFile(".tmp_\(UUID().uuidString)", old: true)
        let recentTmp = try makeFile(".tmp_\(UUID().uuidString)", old: false)
        let oldRollback = try makeFile(".rollback_\(UUID().uuidString)", old: true)
        let userTmpLookalike = try makeFile(".tmp_notes.txt", old: true)

        // An orphaned staging *directory* (crashed mid-directory-copy), old.
        let oldTmpDir = root.appendingPathComponent(".tmp_\(UUID().uuidString)")
        try fm.createDirectory(at: oldTmpDir, withIntermediateDirectories: true)
        try "partial".write(to: oldTmpDir.appendingPathComponent("inner.bin"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldTmpDir.path)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        let scan = OrphanSweeper.findArtifacts(inTrees: [tree], olderThan: Date().addingTimeInterval(-OrphanSweeper.minimumAge))

        #expect(Set(scan.tempPaths) == [oldTmp.path, oldTmpDir.path])
        #expect(scan.rollbackCount == 1)

        let removed = OrphanSweeper.removeTempArtifacts(atPaths: scan.tempPaths, fileManager: fm)

        #expect(removed == 2)
        #expect(!fm.fileExists(atPath: oldTmp.path))
        #expect(!fm.fileExists(atPath: oldTmpDir.path))
        #expect(fm.fileExists(atPath: recentTmp.path))
        #expect(fm.fileExists(atPath: oldRollback.path))
        #expect(fm.fileExists(atPath: userTmpLookalike.path))
    }
}
