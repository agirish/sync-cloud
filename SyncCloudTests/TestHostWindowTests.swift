import Testing
import AppKit
@testable import SyncCloud

/// **The test host puts none of the app's own windows on the user's screen.**
///
/// The host is SyncCloud.app, and it came up with the main window at the user's saved frame:
/// 1575×967, measured on screen for the whole 46 s of an app-target run, over whatever the user was
/// doing — for their own runs, other sessions' and CI's on this Mac alike. Its content under tests
/// is `Color.clear`, so it was a bare window and nothing else. `SyncCloudApp` now suppresses the
/// main scene at launch and turns off restoration for every scene while a test configuration is
/// set.
///
/// Windows a suite builds for itself are that suite's to keep out of sight — buried or parked past
/// every display — and are not counted here. Only the scenes' windows are, found the way
/// `applicationShouldHandleReopen` finds the main window: by the identifier SwiftUI gives a scene's
/// window, which starts with the scene's id.
@MainActor
@Suite struct TestHostWindowTests {

    /// Every `Window` scene `SyncCloudApp` declares.
    static let sceneIds = [SyncCloudApp.mainWindowId, "keyboard-shortcuts", "activity-log", "sync-history"]

    @Test func noSceneWindowIsUp() {
        let up = NSApp.windows.filter { window in
            window.isVisible
                && Self.sceneIds.contains { window.identifier?.rawValue.hasPrefix($0) == true }
        }
        let listing = up.map { "\($0.identifier?.rawValue ?? "-") “\($0.title)” at \($0.frame)" }
            .joined(separator: ", ")
        #expect(up.isEmpty, "the test host put the app's own windows up: \(listing)")
    }
}
