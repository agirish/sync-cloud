import Testing
import Foundation
@testable import Sync

/// Pins the stale-scratch sweep, which unlinks files from the user's real
/// `~/Library/Preferences`. The cost of it being too loose is not a failing test — it is a deleted
/// preference domain — so the deletion path itself is exercised here, not just the predicate.
///
/// The fixtures are the shapes actually observed on 2026-08-03, when 3,551 leaked scratch suites
/// had accumulated (a cold `defaults domains` had gone from ~0.1s to 2.38s) and exactly one real
/// domain in that directory carried a UUID.
///
/// Every test calls `sweepStaleScratchPlists()` directly rather than through `record`'s
/// once-per-process trigger: that trigger fires for whichever test runs first, so routing through
/// it would leave the others asserting against a sweep that never ran.
@Suite struct ScratchPlistSweepTests {

    private static let preferences = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences")

    /// Writes a plist into the real preferences directory, back-dated by `ageSeconds`. Returns its
    /// path; the caller owns cleanup (the sweep may or may not be the thing that removes it).
    private func plant(_ name: String, ageSeconds: TimeInterval) throws -> String {
        let path = "\(Self.preferences)/\(name)"
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: path)
        return path
    }

    /// The sweep's whole purpose: a scratch suite whose run was killed before it could record
    /// itself is unlinked anyway, on shape alone. Both live naming forms, aged past the floor.
    @Test func aStaleScratchSuiteIsSweptWithoutEverHavingBeenRecorded() throws {
        let dash = try plant("SweepTestDash-27F8084A-D4C7-4067-BB25-2B648F8C4153.plist",
                             ageSeconds: 7200)
        let dot = try plant("SweepTestDot.0250379B-9B3A-4D69-97DD-B891BAC60285.plist",
                            ageSeconds: 7200)
        defer { try? FileManager.default.removeItem(atPath: dash)
                try? FileManager.default.removeItem(atPath: dot) }

        scratchDefaultsLedger.sweepStaleScratchPlists()

        #expect(!FileManager.default.fileExists(atPath: dash))
        #expect(!FileManager.default.fileExists(atPath: dot))
    }

    /// The most important test in this file. A real domain in the same directory ends in a UUID
    /// too — `com.openai.chat.RemoteFeatureFlags.164320f2-…` — and the ONLY thing distinguishing
    /// it from a scratch suite is hex case: `UUID().uuidString` is uppercase, that one is not.
    /// Relax the predicate to case-insensitive and this sweep deletes real preferences. Aged well
    /// past the floor, so age is not what is saving it.
    @Test func aRealDomainWithALowercaseUUIDSurvivesTheSweep() throws {
        let real = try plant("com.example.sweeptest.RemoteFeatureFlags.164320f2-9a87-42e0-a5e8-3b112733f6fd.plist",
                             ageSeconds: 7200)
        defer { try? FileManager.default.removeItem(atPath: real) }

        scratchDefaultsLedger.sweepStaleScratchPlists()

        #expect(FileManager.default.fileExists(atPath: real),
                "a lowercase UUID is a real domain, not a scratch suite")
    }

    /// The age floor is what makes the sweep safe to run while other sessions are testing — this
    /// Mac routinely has several worktrees running suites at once. A suite created seconds ago
    /// matches the pattern exactly and must still survive.
    @Test func aLiveScratchSuiteInsideTheAgeFloorSurvives() throws {
        let live = try plant("SweepTestLive-D3BC5A6D-EC81-4AEE-AAD2-C8CD78672D66.plist",
                             ageSeconds: 5)
        defer { try? FileManager.default.removeItem(atPath: live) }

        #expect(ScratchDefaultsLedger.isScratchSuitePlist(
            "SweepTestLive-D3BC5A6D-EC81-4AEE-AAD2-C8CD78672D66.plist"),
                "the fixture must match the predicate, or its survival proves nothing")

        scratchDefaultsLedger.sweepStaleScratchPlists()

        #expect(FileManager.default.fileExists(atPath: live),
                "a suite minutes old may belong to a concurrently running session")
    }

    /// Another project of the owner's leaks test suites into this same directory, and they are
    /// tracked THERE. A SyncCloud run must not delete them: on 2026-08-03 a manual cleanup did,
    /// 11 of them, and the sweep as first landed would have kept doing it on every run. Ownership
    /// is not inferable from the shape — these match the scratch pattern exactly — so this is the
    /// only thing keeping the sweep inside its own house. Aged past the floor, so age is not what
    /// is saving them.
    @Test func anotherProjectsScratchSuitesAreNeverSwept() throws {
        let foreign = try plant("pdfutils.tests.27F8084A-D4C7-4067-BB25-2B648F8C4153.plist",
                                ageSeconds: 7200)
        let alsoForeign = try plant("PDFExportCoordinatorTests-0250379B-9B3A-4D69-97DD-B891BAC60285.plist",
                                    ageSeconds: 7200)
        defer { try? FileManager.default.removeItem(atPath: foreign)
                try? FileManager.default.removeItem(atPath: alsoForeign) }

        scratchDefaultsLedger.sweepStaleScratchPlists()

        #expect(FileManager.default.fileExists(atPath: foreign),
                "pdfutils' suites belong to a different project and are tracked there")
        #expect(FileManager.default.fileExists(atPath: alsoForeign))
    }

    /// Shape cases that never reach the filesystem. Prefixes carry test-function names, so they
    /// contain both separators themselves — the UUID must be matched at the END, not anywhere.
    @Test func thePredicateAcceptsOnlyTheScratchShape() {
        #expect(ScratchDefaultsLedger.isScratchSuitePlist(
            "SettingsTests-testPathOverrides()-89F9B898-ADAC-4BDF-A274-CA0F135E7E70.plist"))
        #expect(ScratchDefaultsLedger.isScratchSuitePlist(
            "WorkspaceTests.garbage-in-new-key.D3BC5A6D-EC81-4AEE-AAD2-C8CD78672D66.plist"))

        #expect(!ScratchDefaultsLedger.isScratchSuitePlist("com.apple.finder.plist"))
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist("com.agirish.SyncCloud.plist"))
        // Mixed case is not what Foundation emits, so it is not ours to delete.
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist(
            "SomeTests-27f8084A-D4C7-4067-BB25-2B648F8C4153.plist"))
        // A bare UUID with no prefix is not a suite this codebase creates.
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist(
            "27F8084A-D4C7-4067-BB25-2B648F8C4153.plist"))
        // Right shape, wrong extension — the sweep only ever unlinks plists.
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist(
            "ColumnPreviewLayoutTests-27F8084A-D4C7-4067-BB25-2B648F8C4153.txt"))
        // Uppercase hex throughout, but not grouped as a UUID.
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist(
            "Tests-27F8084AD4C7-4067-BB25-2B648F8C41-53.plist"))
        // No separator before the UUID.
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist(
            "Tests27F8084A-D4C7-4067-BB25-2B648F8C4153.plist"))
    }
}
