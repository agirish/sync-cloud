import Testing
import Foundation
import Combine
@testable import Sync

/// Count titles — undo action names (read in Edit ▸ Undo as "Undo Delete 1 Item") and progress
/// titles — inflect their noun for the count and group the number the way the counter under them
/// does. `CopyMoveBehaviorPinTests`, `ProgressAccountingTests` and `UndoRedoLogLabelTests` pin the
/// single-item copy, move and delete names; this suite pins the rule itself and the bulk titles
/// nothing else watches.
@Suite struct CountedNounTests {

    @Test func oneTakesTheSingularAndEveryOtherCountThePlural() {
        #expect(CountedNoun.phrase(1, "Item") == "1 Item")
        #expect(CountedNoun.phrase(2, "Item") == "2 Items")
        #expect(CountedNoun.phrase(0, "file") == "0 files")
        #expect(CountedNoun.phrase(1, "file") == "1 file")
        #expect(CountedNoun.phrase(3, "Copy", plural: "Copies") == "3 Copies")
        #expect(CountedNoun.phrase(1, "Copy", plural: "Copies") == "1 Copy")
    }

    /// "Deleting 7363 Items" sat over a counter reading "3,336 of 7,363". The locale is pinned so
    /// the separator is a fact of the test, not of the machine it runs on.
    @Test func theCountIsGroupedForTheLocale() {
        let us = Locale(identifier: "en_US")
        #expect(CountedNoun.phrase(7363, "Item", locale: us) == "7,363 Items")
        #expect(CountedNoun.phrase(999, "Item", locale: us) == "999 Items")
        #expect(CountedNoun.phrase(7363, "Item", locale: Locale(identifier: "de_DE")) == "7.363 Items")
    }

    // MARK: - Bulk progress titles

    @MainActor
    private func oneDifference(_ fm: MockFileManager, name: String) throws -> FileDifference {
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return FileDifference(
            relativePath: name,
            leftItemPath: "/src/\(name)",
            rightItemPath: "/dst/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing"
        )
    }

    /// Every progress title the manager publishes while `body` runs, in order.
    @MainActor
    private func titles(of manager: FileSyncManager, during body: () async -> Void) async -> [String] {
        var seen: [String] = []
        let subscription = manager.$activeProgress.sink { if let p = $0 { seen.append(p.localizedDescription) } }
        await body()
        subscription.cancel()
        return seen
    }

    /// A bulk MOVE was titled "Syncing N files", as if it copied.
    @MainActor
    @Test func aBulkMoveIsTitledMovingAndABulkCopySyncing() async throws {
        let moveFM = MockFileManager()
        let mover = FileSyncManager(fileManager: moveFM)
        let moved = try oneDifference(moveFM, name: "moved.txt")
        mover.rawDifferences = [moved]
        mover.differences = [moved]
        let moveTitles = await titles(of: mover) {
            await mover.syncAll(direction: .copyToRight, isMove: true, confirmed: true)
        }
        #expect(moveFM.virtualDisk["/dst/moved.txt"] != nil && moveFM.virtualDisk["/src/moved.txt"] == nil,
                "the move never ran, so its title proves nothing")
        #expect(moveTitles == ["Moving 1 file"])

        let copyFM = MockFileManager()
        let copier = FileSyncManager(fileManager: copyFM)
        let a = try oneDifference(copyFM, name: "a.txt")
        let b = try oneDifference(copyFM, name: "b.txt")
        copier.rawDifferences = [a, b]
        copier.differences = [a, b]
        let copyTitles = await titles(of: copier) {
            await copier.syncAll(direction: .copyToRight, confirmed: true)
        }
        #expect(copyFM.virtualDisk["/dst/a.txt"] != nil && copyFM.virtualDisk["/src/a.txt"] != nil)
        #expect(copyTitles == ["Syncing 2 files"])
    }

    @MainActor
    @Test func copyingToMatchDatesNamesOneFileInTheSingular() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        let diff = try oneDifference(fm, name: "dated.txt")
        let seen = await titles(of: manager) {
            await manager.bulkCopyDifferencesLeftToRight([diff], asOf: manager.fileOperationsEpoch)
        }
        #expect(seen == ["Copying 1 file to match dates"])
    }
}
