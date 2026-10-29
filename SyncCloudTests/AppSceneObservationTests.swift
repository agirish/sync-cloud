import Testing
import Foundation
@testable import SyncCloud
import Sync

/// **A manager publish does not re-run the App scene** (speed audit item 9).
///
/// The App held the manager as `@StateObject`, which subscribes the scene to every publish: measured
/// 2026-10-29 in this host, ten publishes ran `SyncCloudApp.body` — and its ~90-item `.commands`
/// tree — ten times. Held as `@State` it runs none, and every reader of the manager below the scene
/// observes it itself. Reverting the property to `@StateObject` turns this red (checked the same
/// day), which is the control a counter that never moves needs.
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
