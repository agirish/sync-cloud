import Foundation
import Testing
@testable import Sync

/// FR10, after a keeper is picked by hand. The scan protects a folder that holds another group's
/// keeper — but only the keepers IT chose. `Pics`, `P/Sub` and `Q/Sub` are identical and `P`, `Q`
/// hold only `Sub`; the scan keeps `P/Sub` and, protecting `P`, removes `Q`. Pick `Q/Sub` as the
/// first group's keeper instead and the second group still removes `Q`, which now holds it: one
/// Apply recommended removed every copy. The last check before removal refuses that.
@Suite struct DuplicateKeeperRepickTests {

    /// The scan of the fixture above, with `Q/Sub` picked by hand as the first group's keeper.
    @MainActor
    private func repickedFixture(_ root: URL) async throws -> FileSyncManager {
        let fm = FileManager.default
        let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)
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
        return manager
    }

    @MainActor
    @Test func aRepickedKeeperIsNeverRemovedByAnotherGroup() async throws {
        let root = try makeCanonicalTempRoot(prefix: "KeeperRepick")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let manager = try await repickedFixture(root)

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        let survivors = ["Downloads/Pics", "Work/A/P/Sub", "Work/B/Q/Sub"].filter {
            fm.fileExists(atPath: root.appendingPathComponent($0 + "/a.jpg").path)
        }
        #expect(!survivors.isEmpty, "every copy was removed")
        #expect(survivors.contains("Work/B/Q/Sub"), "the keeper picked by hand was removed")
    }

    /// That refusal is not drift — nothing changed; the keepers moved under the copy — so the batch
    /// must not report the refused group as having "changed since the scan" (it used to share the
    /// `.drifted` kind, and every banner and log line that kind drives).
    @MainActor
    @Test func theBatchSaysTheRefusedCopyHoldsAKeeperNotThatItChanged() async throws {
        let root = try makeCanonicalTempRoot(prefix: "KeeperRepickBanner")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await repickedFixture(root)

        await manager.applyRecommendedDuplicates(manager.recommendedDuplicateGroups)

        let text = try #require(manager.banner?.message, "the batch posted no banner")
        #expect(text.contains("1 group holds a copy another group keeps and was left alone"), "\(text)")
        #expect(!text.contains("changed"), "a refusal for holding a keeper was reported as a change: \(text)")
    }

    /// The same refusal through the single-group resolve: the scan's `P`/`Q` group, whose removal
    /// `Q` now holds the keeper picked by hand.
    @MainActor
    @Test func theSingleResolveSaysTheRefusedCopyHoldsAKeeperNotThatItChanged() async throws {
        let root = try makeCanonicalTempRoot(prefix: "KeeperRepickSingle")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try await repickedFixture(root)
        let pq = try #require(manager.duplicateGroups.first { $0.keeper.path.hasSuffix("/Work/A/P") },
                              "the premise: the scan kept P over Q")

        let resolved = await manager.resolveDuplicateGroup(pq)

        #expect(!resolved)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Work/B/Q/Sub/a.jpg").path))
        let text = try #require(manager.banner?.message, "the resolve posted no banner")
        #expect(text.contains("holds the copy another duplicate group keeps"), "\(text)")
        #expect(!text.contains("changed"), "a refusal for holding a keeper was reported as a change: \(text)")
    }

    /// A batch refused whole names each cause only where it was the cause.
    @Test func anAllRefusedBatchNamesOnlyTheCausesItChecked() {
        let banner = FileSyncManager.allRefusedBatchBanner
        #expect(banner(2, 0, 2) == "These groups hold copies other duplicate groups keep — rescan before removing copies.")
        #expect(banner(2, 2, 0).hasPrefix("These groups couldn’t be fully checked"))
        #expect(banner(3, 1, 0) == "These groups changed since they were scanned — rescan before removing copies.")
        let mixed = banner(3, 1, 1)
        #expect(mixed.contains("hold copies other duplicate groups keep") && mixed.contains("the rest changed or couldn’t be checked"),
                "\(mixed)")
    }

    /// The gate's FR10 check used to ask every keeper about every copy — `keeper == key ||
    /// keeper.isInsideDirectory(anyOf: [key])` — which is O(copies × keepers) on the main actor.
    /// It now builds one set up front. This pins that the set answers exactly what the old
    /// predicate answered, over keepers that share prefixes, nest, repeat, and arrive in an order
    /// where a shorter keeper follows a longer one (the early stop has to stay correct then).
    @Test func theKeeperSetAnswersWhatTheOldPerKeeperWalkAnswered() {
        let keepers = ["/r/Work/B/Q/Sub", "/r/Docs", "/r/Work/B/Q/Sub", "/r/Work/A/P",
                       "/r/Work", "/r/x/y/z/deep", "/r/x/y2"]
        let held = FileSyncManager.pathsHoldingKeepers(keepers)
        let candidates = ["/r/Work/B/Q/Sub", "/r/Work/B/Q", "/r/Work/B", "/r/Work", "/r", "",
                          "/r/Work/A/P", "/r/Work/A", "/r/Work/A/P/inner", "/r/Docs",
                          "/r/DocsBackup", "/r/Doc", "/r/Work/B/Q/Sub2", "/r/Work/B/Q/Su",
                          "/r/x/y/z", "/r/x/y", "/r/x", "/r/x/y/z/deep", "/r/x/y2", "/r/x/y2/k",
                          "/elsewhere", "/r/Work/C"]
        for key in candidates {
            let old = keepers.contains { $0 == key || $0.isInsideDirectory(anyOf: [key]) }
            #expect(held.contains(key) == old, "\(key): the old walk said \(old)")
        }
        // Not vacuous either way: the fixture holds both answers.
        #expect(candidates.contains { held.contains($0) })
        #expect(candidates.contains { !held.contains($0) })
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
