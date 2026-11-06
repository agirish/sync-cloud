import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// A started Filing scan must account for itself in the log, however it ends.
/// `findFilingSuggestions` is a run of `await`s and cancellation checks, and a silent exit leaves
/// the log unable to tell "ran and found nothing" from "never ran". These pin the three exits that
/// produce no suggestions and the one that does. Folder names are unique per test because
/// `Logger.shared` is process-wide and suites run in parallel.
@Suite struct FilingScanAbandonmentLogTests {

    /// The first line `log` captured containing `fragment`. A capture, not the shared buffer, so
    /// other suites logging past the line can't push it out.
    @MainActor
    private func loggedLine(_ log: LogCapture, containing fragment: String) async -> String? {
        await log.entries.first { $0.message.contains(fragment) }?.message
    }

    @MainActor
    private func write(_ url: URL, bytes: Int = 32) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// Control: a scan that completes logs its result and nothing about abandonment. Without it, a
    /// `defer` that logged unconditionally would pass every test here.
    @MainActor
    @Test func aScanThatCompletesReportsItsResultAndNotAbandonment() async throws {
        let log = LogCapture()
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonComplete")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("CompletesCleanly/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("CompletesCleanly"),
                                            providerRoot: root)

        #expect(manager.hasSuggestedFiling, "the scan really did run to the publish")
        #expect(await loggedLine(log, containing: "Filing: scanned CompletesCleanly") != nil,
                "a completed scan logs its result")
        #expect(await loggedLine(log, containing: "CompletesCleanly abandoned") == nil,
                "a completed scan must not claim it was abandoned")
    }

    /// Cancellation. The scan is cancelled before its first cancellation check, so it stops in
    /// phase 1, and the line names the phase: "gave up before reading anything" and "gave up after
    /// the expensive classifier pass" must read differently.
    @MainActor
    @Test func aCancelledScanSaysWhichPhaseItStoppedIn() async throws {
        let log = LogCapture()
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonCancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("CancelledMidScan/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        manager.startFindFilingSuggestions(folder: root.appendingPathComponent("CancelledMidScan"),
                                           providerRoot: root)
        // Synchronous, so it lands before the task body first runs: the scan sees cancellation at
        // the check after the loose-file walk, still in phase 1.
        manager.cancelFindFilingSuggestions()
        await manager.filingScanTask?.value

        #expect(!manager.hasSuggestedFiling, "a cancelled scan publishes nothing")
        let line = await loggedLine(log, containing: "CancelledMidScan abandoned")
        #expect(line != nil, "an abandoned scan must say so")
        #expect(line?.contains("while scanning CancelledMidScan") == true,
                "the line names the phase it stopped in, got: \(line ?? "no line")")
        #expect(line?.contains("superseded by a newer scan, or cancelled") == true,
                "the line names why, got: \(line ?? "no line")")
        #expect(await loggedLine(log, containing: "Filing: scanned CancelledMidScan") == nil,
                "a cancelled scan must not log a result")
    }

    /// An auto-rescan logs its announcement before the scan starts, so the announcement must always
    /// be followed by an accounting, here an abandonment naming the phase. Otherwise silence can't
    /// be told from a scan still running (say, an iCloud walk stalled while the display sleeps).
    @MainActor
    @Test func anAnnouncedAutoRescanIsAlwaysFollowedByAnAccounting() async throws {
        let log = LogCapture()
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonAutoRescan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let downloads = root.appendingPathComponent("AnnouncedThenCancelled")
        try write(downloads.appendingPathComponent("Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        let defaults = ScratchDefaults("filingAbandonAutoRescan")
        manager.persistedUIStateDefaults = defaults
        // The consent an auto-rescan needs: this exact folder was scanned to completion before.
        defaults.set([downloads.path], forKey: FileSyncManager.lastFilingScanFolderKey)

        #expect(manager.autoRescanFilingIfEligible(folder: downloads, providerRoot: root),
                "the auto-rescan is eligible and starts")
        #expect(await loggedLine(log, containing: "auto-rescanning AnnouncedThenCancelled") != nil,
                "the announcement really was written before the scan could run")

        manager.cancelFindFilingSuggestions()
        await manager.filingScanTask?.value

        #expect(!manager.hasSuggestedFiling)
        let line = await loggedLine(log, containing: "AnnouncedThenCancelled abandoned")
        #expect(line != nil, "an announced scan that produces nothing must account for itself")
        #expect(line?.contains("while scanning AnnouncedThenCancelled") == true,
                "and name the phase, got: \(line ?? "no line")")
    }

    /// The re-entrancy guard returns before `beginScan`, the one exit the `defer` can't cover. It
    /// reports itself as a no-op, not an abandonment: the running scan covers the same ground.
    @MainActor
    @Test func aScanRefusedBecauseOneIsRunningSaysThatInsteadOfNothing() async throws {
        let log = LogCapture()
        let root = try makeCanonicalTempRoot(prefix: "FilingAbandonGuard")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("AlreadyRunning/Tesla Auto Policy.pdf"))

        let manager = FileSyncManager()
        manager.isSuggestingFiles = true
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("AlreadyRunning"),
                                            providerRoot: root)

        #expect(await loggedLine(log, containing: "AlreadyRunning not started") != nil,
                "the re-entrancy guard reports itself")
        #expect(await loggedLine(log, containing: "AlreadyRunning abandoned") == nil,
                "a scan that never started is not an abandoned one")
    }
}
