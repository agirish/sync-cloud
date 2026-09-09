import Testing
import Foundation
@testable import SyncCloud

/// **What the window has to keep for the workspaces it destroys.**
///
/// `verticalSplit` lays the window out as a `switch` over `contentLayout`, and each arm is a
/// separate SwiftUI identity — so moving between Browse, Compare, Organize and Edit tears the
/// outgoing workspace's view tree down and builds the incoming one from nothing. Anything a
/// workspace kept in its own `@State` went with it.
///
/// The fix is not to stop that happening. It is to hold the handful of things a reader actually set
/// somewhere that outlives it, and `ContentView` is the only view in the app that does — it is
/// mounted once for the window's life. These scans hold the call sites, because nothing rendered
/// notices a host quietly going back to keeping nothing.
@MainActor
@Suite struct WorkspaceSessionHoistTests {

    /// **`@State`, not `@StateObject`, and the difference is a window-wide re-render.**
    ///
    /// The window must OWN the lens session — so it survives the switches that destroy
    /// `LensWorkspaceView` — without OBSERVING it. `@StateObject` here would subscribe this
    /// four-thousand-line body to every keystroke in Organize's search field and every duplicate
    /// resolve. `@State` on a reference type stores without subscribing; the lens observes it and
    /// re-renders alone.
    @Test func theWindowOwnsTheLensSessionWithoutObservingIt() throws {
        let source = try macAppSources()
        #expect(source.contains("@State private var lensSession = LensWorkspaceSession()"),
                "the window's lens session is missing or is a @StateObject — a @StateObject here subscribes the whole window to Organize's typing")
        #expect(source.contains("session: lensSession"),
                "the lens is no longer handed the window's session, so every narrowing resets on the next switch")
    }

    /// The pane's open folders are held per SIDE by the window.
    ///
    /// Per side rather than per workspace because Browse's pane, the lens rail and Compare's left
    /// pane are all the left pane — one tree, one path, one provider — so a folder opened in one
    /// should be open in the others. Two sets because Compare shows both at once.
    @Test func theWindowHoldsEachPanesOpenFolders() throws {
        let source = try macAppSources()
        #expect(source.contains("@State var leftTreeExpanded: Set<String> = []"))
        #expect(source.contains("@State var rightTreeExpanded: Set<String> = []"))
        #expect(source.contains("hostExpanded: pane.isLeft ? $leftTreeExpanded : $rightTreeExpanded"),
                "the pane no longer receives the window's expansion set — its open folders die with the workspace again")
    }
}
