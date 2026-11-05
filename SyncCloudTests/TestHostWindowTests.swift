import Testing
import FileExplorer
import AppKit
@testable import SyncCloud

/// The test host puts none of the app's own windows on the user's screen.
///
/// The host is SyncCloud.app, so without care its main window comes up at the user's saved frame
/// over whatever they are doing, for the whole run. `SyncCloudApp` suppresses the main scene and
/// turns off restoration while a test configuration is set.
///
/// Windows a suite builds for itself are its own to keep out of sight and aren't counted. Scene
/// windows are found as `applicationShouldHandleReopen` finds the main one: by the identifier
/// SwiftUI gives them, which starts with the scene's id.
@MainActor
@Suite struct TestHostWindowTests {

    /// Every `Window` scene `SyncCloudApp` declares.
    static let sceneIds = [SyncCloudApp.mainWindowId, "keyboard-shortcuts", ActivityCenter.windowID]

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
