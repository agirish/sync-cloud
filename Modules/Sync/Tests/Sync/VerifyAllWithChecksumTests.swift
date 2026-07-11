import Testing
import Foundation
@testable import Sync

/// Pins `verifyAllWithChecksum` end-to-end ahead of refactoring its parallel-worker scaffolding:
/// identical / differed / skipped classification, the summary banner wording, the
/// verified-identical hand-off to the copy dialog, and progress cleanup. Uses real temp files —
/// the checksummer reads file contents from the real filesystem.
@Suite struct VerifyAllWithChecksumTests {

    @MainActor
    @Test func testVerifyAllClassifiesAndReportsResults() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("VerifyAllPin-\(UUID().uuidString)")
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // same.txt: identical content on both sides. diff.txt: same size, different bytes.
        // gone.txt: right side missing, so hashing fails and the item counts as skipped.
        try Data("identical".utf8).write(to: left.appendingPathComponent("same.txt"))
        try Data("identical".utf8).write(to: right.appendingPathComponent("same.txt"))
        try Data("aaaa".utf8).write(to: left.appendingPathComponent("diff.txt"))
        try Data("bbbb".utf8).write(to: right.appendingPathComponent("diff.txt"))
        try Data("orphan".utf8).write(to: left.appendingPathComponent("gone.txt"))

        func dateDiff(_ name: String, size: Int) -> FileDifference {
            FileDifference(
                relativePath: name,
                leftItemPath: left.appendingPathComponent(name).path,
                rightItemPath: right.appendingPathComponent(name).path,
                type: .differentDates,
                action: .copyToRight,
                description: "Different dates",
                leftFileSize: size,
                rightFileSize: size
            )
        }
        let identical = dateDiff("same.txt", size: 9)
        let differed = dateDiff("diff.txt", size: 4)
        let skipped = dateDiff("gone.txt", size: 6)

        let manager = FileSyncManager()
        // No collision or delete prompt can fire here, but the seams stay mocked so no NSAlert
        // could ever appear if that changes.
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }
        manager.rawDifferences = [identical, differed, skipped]
        manager.differences = [identical, differed, skipped]

        await manager.verifyAllWithChecksum()

        // Only the identical item is offered for the follow-up copy.
        #expect(manager.verifiedIdenticalForCopy?.map(\.id) == [identical.id])
        // Differed/skipped items make the summary a warning, not a success.
        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Verify All: 1 identical; 1 differed; 1 skipped")
        #expect(manager.banner?.severity == .warning)
        // Progress state is fully torn down.
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.activeProgress == nil)
        // Verification alone resolves nothing; the list still holds all three.
        #expect(manager.differences.count == 3)
    }
}
