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
        private var _args: [(String, URL)] = []
        func note(_ id: String, _ dir: URL) { lock.withLock { _onMain.append(Thread.isMainThread); _args.append((id, dir)) } }
        var args: [(String, URL)] { lock.withLock { _args } }
    }

    /// A read that waits for `open()` (bounded: a failing test must not hang), then answers `date`.
    final class GatedRead: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let date: Date
        init(_ date: Date) { self.date = date }
        func open() { gate.signal() }
        var read: @Sendable (String, URL) -> Date? {
            { [self] _, _ in _ = gate.wait(timeout: .now() + 10); return date }
        }
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
    private func scratchProfiles(id: String = "t") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-reads-\(UUID().uuidString)/profiles")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FilingProfileStore.writeProfile(
            FolderProfile(profileId: id, root: "/root", folders: [:], personTokens: []), in: dir)
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
            calls.note(id, dir)
            return stamp
        })

        #expect(attached, "the fixture's profile was not attached — the test proves nothing")
        #expect(manager.filingSurveyedAt == nil, "the date was set before attach returned")
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        #expect(calls.onMain == [false], "read once, and not on the main thread")
        #expect(calls.args.map(\.0) == ["t"] && calls.args.map(\.1) == [profiles],
                "read for the attached profile, in its directory")
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

    /// Reads that land out of order: only the latest attach's date is published. Three attaches,
    /// because the count used to restart once a read had landed, so the third shared the first's
    /// number and the newest date was dropped.
    @Test func onlyTheLatestAttachPublishesItsDate() async throws {
        let profiles = try scratchProfiles()
        defer { try? FileManager.default.removeItem(at: profiles.deletingLastPathComponent()) }
        let manager = FileSyncManager()
        let first = GatedRead(Date(timeIntervalSince1970: 1_000))
        let last = GatedRead(Date(timeIntervalSince1970: 3_000))

        FilingArtifacts.attach(to: manager, profilesDirectory: profiles, readSurveyedAt: first.read)
        FilingArtifacts.attach(to: manager, profilesDirectory: profiles,
                               readSurveyedAt: { _, _ in Date(timeIntervalSince1970: 2_000) })
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        FilingArtifacts.attach(to: manager, profilesDirectory: profiles, readSurveyedAt: last.read)
        let latest = FilingArtifacts.surveyDateRead(for: manager)

        first.open()
        try await Task.sleep(for: .milliseconds(200))   // let the stale read land, if it would
        last.open()
        await latest?.value

        #expect(manager.filingSurveyedAt == Date(timeIntervalSince1970: 3_000))
    }

    /// Attaching a different profile drops the old one's date at once, rather than showing it
    /// under the new profile until the new read lands.
    @Test func switchingProfilesClearsTheOldDate() async throws {
        let a = try scratchProfiles(id: "a")
        let b = try scratchProfiles(id: "b")
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        let manager = FileSyncManager()
        FilingArtifacts.attach(to: manager, profilesDirectory: a,
                               readSurveyedAt: { _, _ in Date(timeIntervalSince1970: 1_000) })
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        #expect(manager.filingSurveyedAt == Date(timeIntervalSince1970: 1_000))

        let slow = GatedRead(Date(timeIntervalSince1970: 2_000))
        FilingArtifacts.attach(to: manager, profilesDirectory: b, readSurveyedAt: slow.read)
        #expect(manager.filingSurveyedAt == nil, "profile a's date stood under profile b")
        slow.open()
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        #expect(manager.filingSurveyedAt == Date(timeIntervalSince1970: 2_000))
    }

    /// A read for a profile the manager has since left (Undo, the survey replay) is dropped.
    @Test func aReadForAProfileSinceLeftIsDropped() async throws {
        let profiles = try scratchProfiles()
        defer { try? FileManager.default.removeItem(at: profiles.deletingLastPathComponent()) }
        let manager = FileSyncManager()
        let slow = GatedRead(Date(timeIntervalSince1970: 1_000))
        FilingArtifacts.attach(to: manager, profilesDirectory: profiles, readSurveyedAt: slow.read)
        manager.filingProfileDirectoryId = "elsewhere"
        slow.open()
        await FilingArtifacts.surveyDateRead(for: manager)?.value
        #expect(manager.filingSurveyedAt == nil)
    }
}
