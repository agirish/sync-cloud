@testable import SyncCloud
import Testing
import Foundation

/// **That the app actually hands each pane its scroll memory**, and names the pane's surface by
/// workspace AND side.
///
/// `paneScrollMemory` defaults to nil in the environment, and a pane with no memory scrolls exactly as
/// it always did — so dropping the app's wiring breaks nothing any test can see, and the only symptom
/// is the one this was built to end: every workspace switch putting the columns back at their first.
/// Scanned against the app's own source for `PaneColumnsGraftWiringTests`' reason: `ContentView` is a
/// `View` with `@State` and cannot be instantiated here.
@Suite struct PaneScrollMemoryWiringTests {

    @Test func everyPaneIsHandedTheWindowsScrollMemory() throws {
        let code = try PaneColumnsGraftWiringTests.appSource()
        #expect(code.contains("@State private var paneScrollMemory = PaneScrollMemory()"),
                "ContentView keeps no scroll memory — nothing outlives a workspace switch")
        #expect(code.contains(".environment(\\.paneScrollMemory,"),
                "the panes are not handed the memory — every switch starts the columns at their first again")
    }

    /// The surface is the workspace and the side. Per side alone, Browse's position would be put back
    /// on Organize's narrower rail; per workspace alone, the two Compare panes would share one.
    @Test func theSurfaceIsTheWorkspaceAndTheSide() throws {
        let code = try PaneColumnsGraftWiringTests.appSource()
        #expect(code.contains(#"surface: "\(selectedWorkspace.rawValue).\(pane.isLeft ? "left" : "right")""#),
                "the scroll memory's surface no longer names both the workspace and the side")
    }
}
