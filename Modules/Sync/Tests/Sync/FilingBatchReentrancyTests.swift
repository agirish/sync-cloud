import Testing
import Foundation
@testable import Sync

/// Re-entrancy for the blind "File recommended" batch (`applyRecommendedFiling`).
///
/// Every sibling pass that writes files owns an in-flight latch — `isBulkSyncRunning`
/// (`syncAll`, `bulkCopyDifferencesLeftToRight`), `isApplyingRenames` (`applyRenamePlans`),
/// `mergingGroupIDs` (`mergeDuplicateGroup`), `filingRefineInFlight` / `filingTryAnotherInFlight`
/// (the two Filing round-trips). This one checked only `isVerifyAllRunning`, which is a *different*
/// pass's guard and says nothing about a second batch.
///
/// The overlap is one gesture away: `fileAllButton` is disabled only while a scan runs, its
/// confirmation is an `NSAlert` whose modal run loop lets the first batch's `Task` keep going, and
/// the array both invocations file is the same captured `batch`. Under a second invoke the first
/// one's moves have already happened, so every file fails `performFiling`'s source-exists guard —
/// and the user is told "Couldn't file this item; it was left in place" about files that were
/// filed, under a "Couldn't file N files" banner.
@Suite @MainActor struct FilingBatchReentrancyTests {

    private func write(_ url: URL, bytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// Two loose files, each with a high-confidence **filename**-derived home — the only kind the
    /// blind batch touches. Built by hand rather than scanned so eligibility is a property of the
    /// fixture and not of the router's current scoring.
    private func fixture(_ name: String) throws -> (root: URL, suggestions: [FilingSuggestion]) {
        let root = try makeCanonicalTempRoot(prefix: "FilingBatchReentrancy-\(name)")
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        var suggestions: [FilingSuggestion] = []
        for file in ["Tesla Policy.pdf", "Tesla Registration.pdf"] {
            let src = root.appendingPathComponent("Downloads/\(file)")
            try write(src)
            let dest = FilingDestination(
                path: root.appendingPathComponent("Documents/Vehicles/Tesla").path,
                confidence: .high, reasons: ["name"], newSegments: ["Tesla"])
            suggestions.append(FilingSuggestion(filePath: src.path, fileName: file, size: 4096,
                                                modificationDate: nil, candidates: [dest],
                                                providerRoot: root.path))
        }
        #expect(suggestions.allSatisfy { $0.isBatchEligible },
                "the fixture is not batch-eligible, so this suite would never enter the batch at all")
        return (root, suggestions)
    }

    private func filed(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Documents/Vehicles/Tesla/\(name)").path)
    }

    /// **A second "File all" while the first is still running must be refused, not re-run.**
    ///
    /// The overlap is forced rather than raced: an operation parked on the shared file-operation
    /// queue holds the first batch inside its very first move, so the second invocation is
    /// guaranteed to enter mid-batch. Without a latch it walks the same array, finds every source
    /// already moved, and reports each one as a failure that left the file in place.
    @Test func aSecondFileAllWhileTheFirstIsRunningIsRefused() async throws {
        let (root, suggestions) = try fixture("double")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingSuggestions = suggestions

        // Occupy the file-operation queue. Every move the batch orders chains behind this, so the
        // first batch cannot finish before the second one has entered.
        let gate = Flag(), gateTimedOut = Flag()
        let park = Task { @MainActor in
            await m.enqueueFileOperation { await parkUntilReleased(gate, timedOut: gateTimedOut) }
        }
        // The park is claimed on the main actor inside `enqueueFileOperation`; let it get there.
        await waitUntil("the parking operation claimed the file-operation queue") {
            m.activeFileOperationsCount > 0
        }

        // Whether each invocation found a batch already latched when it entered.
        //
        // **Recorded on both sides, and compared as "exactly one", because `async let` fixes no
        // order.** Probing only the second-declared child failed about one run in three — not
        // because the two did not overlap, but because that child had won the race to the main
        // actor and *was* the batch the other one found latched. A harness assertion that
        // mis-diagnoses a correct run is worse than none; this one is order-free and still says
        // the thing that matters, which is that the two really did overlap. Without it a run
        // where they did not overlap would be indistinguishable from one the latch refused.
        let firstSawLatch = Flag(), secondSawLatch = Flag()
        async let first: Void = { @MainActor in
            firstSawLatch.value = m.isFilingBatchRunning
            await m.applyRecommendedFiling(suggestions)
        }()
        async let second: Void = { @MainActor in
            secondSawLatch.value = m.isFilingBatchRunning
            await m.applyRecommendedFiling(suggestions)
        }()
        // Both invocations run to their first suspension — which, with the queue parked, is inside
        // their first move. Bounded, so a mis-wired harness fails its assertions instead of hanging.
        for _ in 0..<100 { await Task.yield() }
        gate.value = true
        _ = await (first, second)
        _ = await park.value
        #expect(!gateTimedOut.value, "the parked operation timed out, so nothing was held open")

        // Both files really were filed — once.
        #expect(filed(root, "Tesla Policy.pdf"))
        #expect(filed(root, "Tesla Registration.pdf"))
        // …and nothing claimed otherwise.
        let reported = m.currentError.map(String.init(describing:)) ?? "none"
        #expect(m.currentError == nil,
                "a file that was filed was reported as left in place: \(reported)")
        let banner = try #require(m.banner)
        #expect(banner.severity == .success,
                "the batch reported a failure it did not have: “\(banner.message)”")
        #expect(!banner.message.lowercased().contains("couldn't be filed"),
                "the banner counts files that were filed as failures: “\(banner.message)”")
        let sawLatch = (firstSawLatch.value, secondSawLatch.value)
        #expect(firstSawLatch.value != secondSawLatch.value,
                "exactly one invocation should have found the other already running, but they saw \(sawLatch) — they never overlapped, so this test proved nothing")
    }

    /// The other direction — the latch must be **released on every exit**, or the first batch of a
    /// session permanently disables the button. A `defer` release is what makes this pass; moving
    /// the release onto the success path alone would not.
    @Test func aLaterBatchStillRunsAfterAnEarlierOneFinished() async throws {
        let (root, suggestions) = try fixture("sequential")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingSuggestions = suggestions

        await m.applyRecommendedFiling([suggestions[0]])
        #expect(filed(root, "Tesla Policy.pdf"))
        #expect(!m.isFilingBatchRunning, "the latch outlived the batch that took it")

        await m.applyRecommendedFiling([suggestions[1]])
        #expect(filed(root, "Tesla Registration.pdf"),
                "the second batch was refused by a latch the first one never released")
        #expect(m.banner?.severity == .success)
        #expect(m.currentError == nil)
    }

    /// And the early exits must not take the latch either: a refused or empty batch leaves nothing
    /// behind. `isVerifyAllRunning` is the refusal the batch already had; an empty scope is the
    /// other pre-latch return.
    @Test func aRefusedOrEmptyBatchLeavesNoLatchBehind() async throws {
        let (root, suggestions) = try fixture("earlyexit")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager()
        m.filingSuggestions = suggestions

        await m.applyRecommendedFiling([])
        #expect(!m.isFilingBatchRunning)

        m.isVerifyAllRunning = true
        await m.applyRecommendedFiling(suggestions)
        #expect(m.banner?.severity == .warning)
        #expect(!m.isFilingBatchRunning)
        m.isVerifyAllRunning = false

        // Proof the two refusals above did not simply disarm the batch: it still files.
        await m.applyRecommendedFiling(suggestions)
        #expect(filed(root, "Tesla Policy.pdf"))
        #expect(filed(root, "Tesla Registration.pdf"))
    }
}
