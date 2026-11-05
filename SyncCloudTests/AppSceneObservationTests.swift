import Testing
import Foundation
@testable import SyncCloud
import Sync

/// A manager publish does not re-run the App scene. Holding the manager as `@StateObject` would
/// subscribe the scene to every publish, re-running `SyncCloudApp.body` and its ~90-item `.commands`
/// tree each time; held as `@State`, readers below the scene observe it themselves. Changing the
/// property back to `@StateObject` must turn this red.
@MainActor
@Suite struct AppSceneObservationTests {
    @Test func aManagerPublishDoesNotReRunTheScene() async throws {
        let manager = try #require(SyncCloudAppDelegate.sharedSyncManager,
                                   "the host app has no manager — this test measures nothing")
        // The scene really is built in this host, so a count that stays put means something.
        #expect(SyncCloudApp.sceneBodyRuns >= 1, "the App scene never ran in this host")
        try await Task.sleep(nanoseconds: 100_000_000)
        // A quiet window of the same length first: another of the App's own objects (settings,
        // the shortcut reveal) may publish while this runs, and that run is not the manager's.
        let quietStart = SyncCloudApp.sceneBodyRuns
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        let quiet = SyncCloudApp.sceneBodyRuns - quietStart
        let before = SyncCloudApp.sceneBodyRuns
        for _ in 0..<10 {
            manager.objectWillChange.send()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let published = SyncCloudApp.sceneBodyRuns - before
        // Observed, the scene runs once per publish: 10 more than the quiet window.
        #expect(published - quiet < 5,
                "ten manager publishes re-ran the App scene \(published) times (\(quiet) in a quiet window)")
    }
}
