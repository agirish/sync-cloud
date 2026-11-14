import Foundation
import Testing
@testable import Sync

/// One unanswered folder costs a plan one wait, not one per folder. The plan view asks a
/// cloud-only folder through the bounded reads on the main actor; if each waited out the deadline
/// in turn, a family whose provider app had stopped would hold the plan sheet for seconds per
/// folder. Once one has not answered, the rest list as unknown at once.
@Suite struct RestructurePlanStallTests {

    /// A real tree in which every folder in `stalled` is called dataless and its provider never
    /// answers: a listing of one parks until the gate is released. Counts the asks.
    final class StalledFoldersDisk: ForwardingFileManaging<MockFileManager>, @unchecked Sendable {
        private let stalled: Set<String>
        private let gate: ParkGate
        private let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        private let lock = NSLock()
        private var asks = 0

        init(stalled: Set<String>, gate: ParkGate) {
            self.stalled = stalled
            self.gate = gate
            super.init(inner: MockFileManager())
        }

        var providerAsks: Int { lock.lock(); defer { lock.unlock() }; return asks }

        override var datalessFolderReads: FileSyncManager.DatalessFolderReads { reads }

        override func isDataless(at url: URL) -> Bool { stalled.contains(url.path) }

        override func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?,
                                 options m: FileManager.DirectoryEnumerationOptions,
                                 errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            if stalled.contains(u.path) {
                lock.lock(); asks += 1; lock.unlock()
                gate.park(timeout: 120)
            }
            return inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    /// Two cloud-only folders whose app does not answer: the first waits out the deadline and
    /// lists as unknown; the second lists as unknown without asking the provider at all. The
    /// control: a plain folder in the same view still lists.
    @Test(.parksThreads(2)) func aSecondUnansweredFolderDoesNotWaitAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "restructure-stall")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["F/2016/a.pdf", "F/2017/b.pdf", "F/2018/c.pdf"] { try writeText("x", root.appendingPathComponent(path)) }
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

    /// The rule is one wait per family's plan, not per view. The plan sheet holds one view for its
    /// whole presentation, so per view, the first family's stalled folder would list every later
    /// family's cloud-only folders as unknown unasked, though their provider might answer.
    @Test(.parksThreads(2)) func eachFamilyOfAGroupPlanAsksItsOwnFolders() async throws {
        let root = try makeCanonicalTempRoot(prefix: "restructure-stall-group")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["F/2016/Old/a.pdf", "F/2017/Old/b.pdf", "G/2016/Old/c.pdf", "G/2017/Old/d.pdf"] { try writeText("x", root.appendingPathComponent(path)) }
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
