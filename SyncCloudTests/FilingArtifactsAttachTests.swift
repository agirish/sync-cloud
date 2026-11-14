import Foundation
import Testing
@testable import SyncCloud
import Sync

/// Where the app tells the engine its artifacts live. A fresh Mac has no profile and still needs a
/// profiles directory: the path is a fact about the machine, not something a profile carries, and
/// handing it over only when a profile exists would stop the walk that creates the first profile
/// from running on the one machine that has none.
@MainActor
@Suite struct FilingArtifactsAttachTests {

    /// The engine is told where profiles live even when there is no profile to attach; otherwise
    /// setup's Learn fails with `no profiles directory was configured` before reading a folder.
    ///
    /// An empty folder of its own stands in for the fresh Mac: the default directory holds the
    /// user's own profile on his Mac, which would take the other path and attach his data.
    @Test func aMachineWithNoProfileStillLearnsWhereProfilesLive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilingArtifactsAttachTests-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager.scratch()
        #expect(manager.filingProfilesDirectory == nil, "the fixture was already configured")

        let attached = FilingArtifacts.attach(to: manager, profilesDirectory: profiles)

        #expect(!attached, "the empty folder held a profile — this is not the fresh-install path")
        #expect(manager.filingProfilesDirectory?.path == profiles.path,
                "a Mac with no profile cannot write its first one — this is the fresh-install path")
        #expect(manager.contentIndexDirectory?.standardizedFileURL.path == root.standardizedFileURL.path)
    }
}
