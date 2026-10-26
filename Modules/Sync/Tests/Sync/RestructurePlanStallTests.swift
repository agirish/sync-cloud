import Foundation
import Testing
@testable import Sync

/// **One unanswered folder costs a plan one wait, not one per folder** (review R8).
///
/// The plan view asks a cloud-only folder through the bounded reads, but each dataless folder
/// waited out the deadline the first time it went unanswered, on the main actor, one after
/// another — a family of cloud-only folders whose app had stopped held the plan sheet five
/// seconds per folder. Once one has not answered, the rest list as unknown at once.
@Suite struct RestructurePlanStallTests {

    /// A real tree in which every folder in `stalled` is called dataless and its provider never
    /// answers: a listing of one parks until the gate is released. Counts the asks.
    final class StalledFoldersDisk: FileManaging, @unchecked Sendable {
        private let inner = MockFileManager()
        private let stalled: Set<String>
        private let gate: ParkGate
        let datalessFolderReads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        private let lock = NSLock()
        private var asks = 0

        init(stalled: Set<String>, gate: ParkGate) {
            self.stalled = stalled
            self.gate = gate
        }

        var providerAsks: Int { lock.lock(); defer { lock.unlock() }; return asks }

        func isDataless(at url: URL) -> Bool { stalled.contains(url.path) }

        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?,
                        options m: FileManager.DirectoryEnumerationOptions,
                        errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            if stalled.contains(u.path) {
                lock.lock(); asks += 1; lock.unlock()
                gate.park(timeout: 120)
            }
            return inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }

        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: p, isDirectory: d)
        }
        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
        func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
        func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
        }
        func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
        func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: u, resultingItemURL: o)
        }
        func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
        func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
            try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
        }
    }

    /// Two cloud-only folders whose app does not answer: the first waits out the deadline and
    /// lists as unknown; the second lists as unknown without asking the provider at all. The
    /// control: a plain folder in the same view still lists.
    @Test(.parksThreads(2)) func aSecondUnansweredFolderDoesNotWaitAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "restructure-stall")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["F/2016/a.pdf", "F/2017/b.pdf", "F/2018/c.pdf"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let gate = ParkGate()
        defer { gate.release.signal(); gate.release.signal() }
        let disk = StalledFoldersDisk(stalled: [root.appendingPathComponent("F/2016").path,
                                                root.appendingPathComponent("F/2017").path],
                                      gate: gate)
        let view = RestructureTreeView.fromDisk(root: root, fileManager: .default, contentsFrom: disk)

        #expect(view.files("F/2016") == nil, "a folder that did not answer was listed")
        try #require(disk.providerAsks == 1, "the premise: the first folder asked its provider")
        #expect(view.files("F/2017") == nil, "a folder that did not answer was listed")
        #expect(disk.providerAsks == 1, "the second unanswered folder waited on its provider too")
        #expect(view.files("F/2018") == ["c.pdf"], "a folder on this Mac stopped listing")
    }

    /// The rule is one wait per family's PLAN, not per view (review C7). The plan sheet holds
    /// one view for its whole presentation, so in a group plan the first family's stalled folder
    /// listed every later family's cloud-only folders as unknown without asking them — a family
    /// whose provider would have answered was refused unasked. Each family now asks once.
    @Test(.parksThreads(2)) func eachFamilyOfAGroupPlanAsksItsOwnFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "restructure-stall-group")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["F/2016/Old/a.pdf", "F/2017/Old/b.pdf", "G/2016/Old/c.pdf", "G/2017/Old/d.pdf"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let gate = ParkGate()
        defer { gate.release.signal(); gate.release.signal() }
        let disk = StalledFoldersDisk(stalled: [root.appendingPathComponent("F/2016").path,
                                                root.appendingPathComponent("G/2016").path],
                                      gate: gate)
        let view = RestructureTreeView.fromDisk(root: root, fileManager: .default,
                                                contentsFrom: disk).memoized()

        let plans = RestructurePlanner.groupManifests(
            families: ["F", "G"], mapping: RestructureMapping(rows: [.init(source: "Old", target: "New")]),
            kind: .shape, in: view, profileId: "t", manifestIdPrefix: "group", createdAt: "x")

        try #require(plans.count == 2)
        #expect(disk.providerAsks == 2, "the second family's cloud-only folder was never asked")
    }
}
