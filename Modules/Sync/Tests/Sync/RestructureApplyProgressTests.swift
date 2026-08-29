import Foundation
import Testing
@testable import Sync

/// §5.5's eight steps, published as they run (proposal O7). The engine already marked its own
/// boundaries; this is about what a watcher can see, and what it costs to let them see it.
@Suite struct RestructureApplyProgressTests {

    /// **The order is the point.** The inverse reaches disk before anything moves and the verify
    /// is a separate pass afterwards — that sequence is the trust the design paid for, and a
    /// checklist that showed it out of order would be worse than none.
    @Test func theStagesRunInTheOrderTheEngineDoesThem() {
        #expect(RestructureApplyProgress.Stage.allCases
                    == [.guards, .inverse, .operations, .verify, .rederive, .artifacts])
        #expect(RestructureApplyProgress.Stage.guards < .inverse)
        #expect(RestructureApplyProgress.Stage.inverse < .operations,
                "the inverse is on disk BEFORE the first operation")
        #expect(RestructureApplyProgress.Stage.operations < .verify,
                "the verifier runs after the moves, from its own code path")
        #expect(RestructureApplyProgress.Stage.verify < .rederive)
    }

    /// Each stage says the thing being done. The inverse line is the one that has to be
    /// unmistakable, because it is the whole argument for the design.
    @Test func everyStageSaysWhatIsHappening() {
        for stage in RestructureApplyProgress.Stage.allCases {
            #expect(!RestructureApplyProgress.label(stage).isEmpty)
        }
        #expect(RestructureApplyProgress.label(.inverse).contains("before anything moves"))
        #expect(RestructureApplyProgress.label(.verify).contains("second code path"))
        #expect(Set(RestructureApplyProgress.Stage.allCases.map(RestructureApplyProgress.label))
                    .count == RestructureApplyProgress.Stage.allCases.count,
                "two stages sharing a line would be one stage")
    }

    /// The operations line carries its count; every other stage carries none, because there is
    /// nothing to count in it.
    @Test func onlyTheOperationsStageCounts() {
        let running = RestructureApplyProgress(stage: .operations, opsDone: 12, opsTotal: 38)
        #expect(running.line() == "Running the operations, re-probing each one — 12 of 38")

        let verifying = RestructureApplyProgress(stage: .verify, opsDone: 38, opsTotal: 38)
        #expect(verifying.line() == RestructureApplyProgress.label(.verify),
                "a stale count from the previous stage would be a number that means nothing")

        let empty = RestructureApplyProgress(stage: .operations)
        #expect(empty.line() == RestructureApplyProgress.label(.operations),
                "no total yet is no count, not '0 of 0'")
    }

    /// **Coalesced through this module's own gate, and measurably so.**
    ///
    /// The first cut invented a wall-clock interval, which `ProgressPublishGate`'s doc explicitly
    /// rejects — an interval is unbounded in total (a long landing publishes forever) and can only
    /// be tested against a clock seam. This drives a landing of 300 operations and counts the
    /// publishes: a percent gate caps any run at ~101, and the assertion is that the count is far
    /// below the operation count rather than that a constant sits in a range.
    @Test func theOperationCounterIsCoalescedFarBelowOnePerOperation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coalesce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var actions: [RestructureManifest.Action] = []
        for i in 0..<300 {
            let dir = root.appendingPathComponent("s\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
            actions.append(.init(action: .moveDir, src: "s\(i)", dst: "d\(i)",
                                 movesWholeFolder: true))
        }
        let reports = Reports()
        _ = FileSyncManager.executeRestructureActions(
            actions, root: root.path, fm: FileManager.default,
            onProgress: { reports.append($0) })

        let seen = reports.values
        #expect(seen.last == 300, "the run still lands on its true total")
        #expect(seen.count <= 101,
                "a percent gate caps any run at ~101 publishes; got \(seen.count)")
        #expect(seen.count < 150,
                "one publish per operation is the storm the gate exists to stop")
        #expect(seen == seen.sorted())
    }

    /// The executor reports through the hook, coalesced, and **always ends on the true total** —
    /// the last window may not have elapsed, and a checklist stuck at "34 of 38" over a finished
    /// landing is the one number it must never show.
    @Test func theExecutorAlwaysReportsItsFinalCount() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var actions: [RestructureManifest.Action] = []
        for i in 0..<12 {
            let dir = root.appendingPathComponent("src\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"))
            actions.append(.init(action: .moveDir, src: "src\(i)", dst: "dst\(i)",
                                 movesWholeFolder: true))
        }
        // A `keep` is the signature block, not an operation — the total the sheet shows is
        // `operationCount`, so the reports must not count it either.
        actions.append(.init(action: .keep, src: "src0"))

        let reports = Reports()
        let execution = FileSyncManager.executeRestructureActions(
            actions, root: root.path, fm: FileManager.default,
            onProgress: { done in reports.append(done) })

        #expect(execution.foldersMovedWhole == 12)
        let seen = reports.values
        #expect(seen.last == 12, "the final count is forced even if its window had not elapsed")
        #expect(seen == seen.sorted(), "a counter that went backwards would be unreadable")
        #expect(seen.allSatisfy { $0 <= 12 }, "a keep must not be counted as an operation")
    }

    /// A tiny thread-safe sink — the hook is `@Sendable` and called from the executor's own
    /// context, which is exactly why it may not close over a plain `var`.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        func append(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
