@testable import SyncCloud
import Testing
import Foundation

/// The app hands each pane its scroll memory, and names the pane's surface by workspace and side.
/// `paneScrollMemory` defaults to nil, and a pane without it still scrolls, so dropping the wiring
/// breaks nothing a test sees; every workspace switch would just put the columns back at their
/// first. A source scan, as in `PaneColumnsGraftWiringTests`: `ContentView` can't be built here.
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
