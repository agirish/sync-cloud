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
        let before = SyncCloudApp.sceneBodyRuns
        for _ in 0..<10 {
            manager.objectWillChange.send()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(SyncCloudApp.sceneBodyRuns == before,
                "ten manager publishes re-ran the App scene \(SyncCloudApp.sceneBodyRuns - before) times")
    }
}
