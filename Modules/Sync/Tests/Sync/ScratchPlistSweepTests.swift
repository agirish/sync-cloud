import Testing
import Foundation
@testable import Sync

/// Pins the stale-scratch sweep, which unlinks files from the user's real `~/Library/Preferences`.
/// Too loose a sweep costs a deleted preference domain, not a failing test, so the deletion path
/// itself is exercised here, not just the predicate. The fixtures are real observed shapes. Every
/// test calls `sweepStaleScratchPlists()` directly: `record`'s once-per-process trigger fires for
/// whichever test runs first, so the others would assert against a sweep that never ran.
@Suite struct ScratchPlistSweepTests {

    private static let preferences = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Preferences")

    /// Writes a plist into the real preferences directory, back-dated by `ageSeconds`, and returns
    /// its path. The caller cleans up, since the sweep may or may not remove it.
    private func plant(_ name: String, ageSeconds: TimeInterval) throws -> String {
        let path = "\(Self.preferences)/\(name)"
        try Data("<plist/>".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: path)
        return path
    }

    /// A scratch suite whose run was killed before it recorded itself is still unlinked, on shape
    /// alone. Both live naming forms, aged past the floor.
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

    /// The most important test here. A real domain in the same directory ends in a UUID too
    /// (`com.openai.chat.RemoteFeatureFlags.164320f2-…`), and only hex case tells it from a scratch
    /// suite: `UUID().uuidString` is uppercase. A case-insensitive predicate would delete real
    /// preferences. Aged past the floor, so age isn't what saves it.
    @Test func aRealDomainWithALowercaseUUIDSurvivesTheSweep() throws {
        let real = try plant("com.example.sweeptest.RemoteFeatureFlags.164320f2-9a87-42e0-a5e8-3b112733f6fd.plist",
                             ageSeconds: 7200)
        defer { try? FileManager.default.removeItem(atPath: real) }

        scratchDefaultsLedger.sweepStaleScratchPlists()

        #expect(FileManager.default.fileExists(atPath: real),
                "a lowercase UUID is a real domain, not a scratch suite")
    }

    /// The age floor makes the sweep safe while other worktrees run suites at once: a suite created
    /// seconds ago matches the pattern exactly and must still survive.
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

    /// Another of the owner's projects leaks test suites into this directory and tracks them
    /// itself; a SyncCloud run must not delete them. They match the scratch pattern exactly, so
    /// ownership can't be read from the shape, and this exclusion is all that keeps the sweep to its
    /// own suites. Aged past the floor, so age isn't what saves them.
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

    /// Shape cases that never reach the filesystem. Prefixes carry test-function names, which
    /// contain both separators, so the UUID must be matched at the end, not anywhere.
    @Test func thePredicateAcceptsOnlyTheScratchShape() {
        #expect(ScratchDefaultsLedger.isScratchSuitePlist(
            "SettingsTests-testPathOverrides()-89F9B898-ADAC-4BDF-A274-CA0F135E7E70.plist"))
        #expect(ScratchDefaultsLedger.isScratchSuitePlist(
            "WorkspaceTests.garbage-in-new-key.D3BC5A6D-EC81-4AEE-AAD2-C8CD78672D66.plist"))

        #expect(!ScratchDefaultsLedger.isScratchSuitePlist("com.apple.finder.plist"))
        #expect(!ScratchDefaultsLedger.isScratchSuitePlist("com.example.SyncCloud.plist"))
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
