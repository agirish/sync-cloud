import Foundation
import Testing
@testable import Sync

/// FR10, after a keeper is picked by hand. The scan protects a folder that holds another group's
/// keeper — but only the keepers IT chose. `Pics`, `P/Sub` and `Q/Sub` are identical and `P`, `Q`
/// hold only `Sub`; the scan keeps `P/Sub` and, protecting `P`, removes `Q`. Pick `Q/Sub` as the
/// first group's keeper instead and the second group still removes `Q`, which now holds it: one
/// Apply recommended removed every copy. The last check before removal refuses that.
@Suite struct DuplicateKeeperRepickTests {

    @MainActor
    @Test func aRepickedKeeperIsNeverRemovedByAnotherGroup() async throws {
        let root = try makeCanonicalTempRoot(prefix: "KeeperRepick")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)
        let fm = FileManager.default
        func sub(_ rel: String, modified: Date) throws {
            let dir = root.appendingPathComponent(rel)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 8192).write(to: dir.appendingPathComponent("a.jpg"))
            try Data(repeating: 0x42, count: 8192).write(to: dir.appendingPathComponent("b.jpg"))
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: dir.path)
        }
        try sub("Downloads/Pics", modified: new)
        try sub("Work/A/P/Sub", modified: new)
        try sub("Work/B/Q/Sub", modified: old)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent("Work/A/P").path)
        try fm.setAttributes([.modificationDate: new], ofItemAtPath: root.appendingPathComponent("Work/B/Q").path)

        let manager = FileSyncManager(fileManager: TrashRefusingDisk())
        manager.permanentDeleteConfirmer = { _ in true }   // no Trash here: removal is for real
        await manager.findDuplicates(root: root, cache: nil, fingerprintCache: nil)
        let subGroup = try #require(manager.duplicateGroups.first { $0.keeper.path.hasSuffix("/P/Sub") },
                                    "the premise: the scan kept P/Sub")
        let qSub = try #require(subGroup.copies.first { $0.path.hasSuffix("/Q/Sub") })
        manager.setKeeper(for: subGroup.id, to: qSub.id)

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        let survivors = ["Downloads/Pics", "Work/A/P/Sub", "Work/B/Q/Sub"].filter {
            fm.fileExists(atPath: root.appendingPathComponent($0 + "/a.jpg").path)
        }
        #expect(!survivors.isEmpty, "every copy was removed")
        #expect(survivors.contains("Work/B/Q/Sub"), "the keeper picked by hand was removed")
    }
}

/// The real disk with the Trash refused, as a volume without one answers. A `FileManager`
/// subclass rather than a wrapper: the walk reads sizes and dates only through a real
/// `FileManager`, and the removal gate's drift re-walk would otherwise see every folder as changed.
private final class TrashRefusingDisk: FileManager, @unchecked Sendable {
    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw CocoaError(.featureUnsupported)
    }
}
