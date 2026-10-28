import Foundation
import Testing
@testable import SyncCloud
import Sync

/// The two launch reads that held the first window, now asked off the main thread (speed audit
/// batch B).
///
/// **Item 4:** whether Apple's on-device model is available — the likely cause of a 5.4 s launch
/// after a macOS update. **Item 5:** the survey date, which parses the whole corpus (about 5 MB)
/// for one footnote, on every launch with a profile.
@MainActor
@Suite struct LaunchReadsOffMainTests {

    /// Whether each call ran on the main thread, in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _onMain: [Bool] = []
        func note() { lock.withLock { _onMain.append(Thread.isMainThread) } }
        var onMain: [Bool] { lock.withLock { _onMain } }
    }

    // MARK: Item 4

    /// `prewarm()` asks availability itself, off the main thread, so launch can install the hook
    /// without asking.
    @Test func prewarmAsksAvailabilityOffTheMainThread() async {
        let calls = Calls()
        let task = OnDeviceFilingClassifier.prewarm(isAvailable: {
            calls.note()
            return false   // never load the real model under test
        })
        await task.value
        #expect(calls.onMain == [false], "asked once, and not on the main thread")
    }

    // MARK: Item 5

    /// A scratch profiles directory holding one active profile.
    private func scratchProfiles() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-reads-\(UUID().uuidString)/profiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "t", root: "/root", folders: [:], personTokens: []), in: dir)
        return dir
    }

    /// `attach` returns before the stamp is read, and the date is published once the read ends.
    @Test func attachReturnsBeforeTheSurveyDateIsRead() async throws {
        let profiles = try scratchProfiles()
        defer { try? FileManager.default.removeItem(at: profiles.deletingLastPathComponent()) }
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let calls = Calls()
        let manager = FileSyncManager()

        let attached = FilingArtifacts.attach(to: manager, profilesDirectory: profiles,
                                              readSurveyedAt: { id, dir in
            calls.note()
            #expect(id == "t" && dir == profiles)
            return stamp
        })

        #expect(attached, "the fixture's profile was not attached — the test proves nothing")
        #expect(manager.filingSurveyedAt == nil, "the date was set before attach returned")
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        #expect(calls.onMain == [false], "read once, and not on the main thread")
        #expect(manager.filingSurveyedAt == stamp, "the date arrives when the read ends")
    }

    /// A re-survey that publishes its own date while the read is in flight keeps it: the read
    /// is older than the survey that just finished.
    @Test func aDateSetWhileTheReadRunsIsNotOverwritten() async throws {
        let profiles = try scratchProfiles()
        defer { try? FileManager.default.removeItem(at: profiles.deletingLastPathComponent()) }
        let gate = DispatchSemaphore(value: 0)
        let manager = FileSyncManager()

        FilingArtifacts.attach(to: manager, profilesDirectory: profiles, readSurveyedAt: { _, _ in
            _ = gate.wait(timeout: .now() + 10)   // bounded: a failing test must not hang
            return Date(timeIntervalSince1970: 1_000)
        })
        let resurveyed = Date(timeIntervalSince1970: 2_000)
        manager.filingSurveyedAt = resurveyed
        gate.signal()
        await FilingArtifacts.surveyDateRead(for: manager)?.value

        #expect(manager.filingSurveyedAt == resurveyed)
    }
}
