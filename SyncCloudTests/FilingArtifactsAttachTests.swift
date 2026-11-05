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
    @Test func aMachineWithNoProfileStillLearnsWhereProfilesLive() {
        let manager = FileSyncManager()
        #expect(manager.filingProfilesDirectory == nil, "the fixture was already configured")

        let attached = FilingArtifacts.attach(to: manager)

        #expect(manager.filingProfilesDirectory != nil,
                "a Mac with no profile cannot write its first one — this is the fresh-install path")
        #expect(manager.contentIndexDirectory != nil)
        // Whether anything was attached depends on the machine, and isn't the point: the directory
        // has to arrive either way.
        _ = attached
    }

    /// The directory is the default one, not something invented.
    @Test func theDirectoryIsTheStoresOwnDefault() {
        let manager = FileSyncManager()
        FilingArtifacts.attach(to: manager)
        #expect(manager.filingProfilesDirectory == FilingProfileStore.defaultDirectory())
    }
}
