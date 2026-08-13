import Testing
import Foundation
import Events
@testable import Sync

/// A started Filing scan must account for itself in the log, however it ends.
///
/// `findFilingSuggestions` is a sequence of `await`s punctuated by cancellation checks, and every
/// one of those was a bare `return`. A scan could therefore be started — announced, in the
/// auto-rescan case — and then abandoned without writing a line, which left the log unable to
/// distinguish "ran and found nothing" from "never ran". These pin the three ways out that
/// produce no suggestions, and the one way out that does.
///
/// Folder names are unique per test on purpose: `Logger.shared` is a process-wide singleton and
/// this suite runs alongside every other, so an assertion that matches on "some scan was
/// abandoned" would be reading other tests' lines. Each test matches only its own folder.
@Suite struct FilingScanAbandonmentLogTests {

    /// True when the shared Logger holds an entry containing `fragment`. Awaiting a fresh log
    /// task first guarantees everything enqueued before it is visible in `entries`.
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await Logger.shared.debug("filing-abandon flush marker").value
        return Logger.shared.entries.first { $0.message.contains(fragment) }?.message
    }

    @MainActor
    private func write(_ url: URL, bytes: Int = 32) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// The positive control, and the reason the two assertions below are worth anything: a scan
    /// that runs to completion logs its result and says nothing about abandonment. Without this,
    /// a `defer` that logged unconditionally would pass every test in this suite.
    @MainActor
    @Test func aScanThatCompletesReportsItsResultAndNotAbandonment() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonComplete")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("CompletesCleanly/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("CompletesCleanly"),
                                            providerRoot: root)

        #expect(manager.hasSuggestedFiling, "the scan really did run to the publish")
        #expect(await loggedLine(containing: "Filing: scanned CompletesCleanly") != nil,
                "a completed scan logs its result")
        #expect(await loggedLine(containing: "CompletesCleanly abandoned") == nil,
                "a completed scan must not claim it was abandoned")
    }

    /// Cancellation — the case that produced no line at all. The scan is cancelled before its
    /// body reaches the first cancellation check, so it stops in phase 1, and the line has to say
    /// so: naming the phase is what separates "gave up before reading anything" from "gave up
    /// after the expensive classifier pass".
    @MainActor
    @Test func aCancelledScanSaysWhichPhaseItStoppedIn() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("CancelledMidScan/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        manager.startFindFilingSuggestions(folder: root.appendingPathComponent("CancelledMidScan"),
                                           providerRoot: root)
        // Synchronous, so it lands before the task body gets its first chance to run: the scan
        // observes cancellation at the check after the loose-file walk, still in phase 1.
        manager.cancelFindFilingSuggestions()
        await manager.filingScanTask?.value

        #expect(!manager.hasSuggestedFiling, "a cancelled scan publishes nothing")
        let line = await loggedLine(containing: "CancelledMidScan abandoned")
        #expect(line != nil, "an abandoned scan must say so")
        #expect(line?.contains("while scanning CancelledMidScan") == true,
                "the line names the phase it stopped in, got: \(line ?? "no line")")
        #expect(line?.contains("superseded by a newer scan, or cancelled") == true,
                "the line names why, got: \(line ?? "no line")")
        #expect(await loggedLine(containing: "Filing: scanned CancelledMidScan") == nil,
                "a cancelled scan must not log a result")
    }

    /// The re-entrancy guard, which returns before `beginScan` and so is the one exit the `defer`
    /// cannot cover. It reports itself, and it reports itself as a no-op rather than as an
    /// abandonment — nothing was given up, the running scan covers the same ground.
    @MainActor
    @Test func aScanRefusedBecauseOneIsRunningSaysThatInsteadOfNothing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonGuard")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("AlreadyRunning/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        manager.isSuggestingFiles = true
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("AlreadyRunning"),
                                            providerRoot: root)

        #expect(await loggedLine(containing: "AlreadyRunning not started") != nil,
                "the re-entrancy guard reports itself")
        #expect(await loggedLine(containing: "AlreadyRunning abandoned") == nil,
                "a scan that never started is not an abandoned one")
    }
}
