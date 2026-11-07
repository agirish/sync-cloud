import Foundation
import Testing
@testable import Dashboard

/// Every icon-only pane-bar rung needs an accessible name. On macOS `.help` sets the accessibility
/// help, never the name, so an icon with only a tooltip announces as nothing.
///
/// A source scan, because assertions against the live accessibility tree pass vacuously with no
/// assistive client attached. This counts the modifiers in the file instead, and fails if the file
/// can't be read.
@Suite struct PaneBarAccessibleNameTests {

    /// The icon-only rungs, by their accessible names.
    static let names = ["View mode", "Collapse the source pane", "Back", "Forward", "New folder",
                        "Sort", "Search this pane", "More pane options", "Hidden files"]

    @Test func everyIconOnlyPaneBarRungHasAName() throws {
        let source = try DashboardSource.read("DashboardViews.swift", atLeast: 5000)
        for name in Self.names {
            #expect(source.contains(".accessibilityLabel(\"\(name)\")"),
                    "the pane-bar rung named “\(name)” lost its accessible name")
        }
    }

    /// Hidden Files shows its state only by a glyph swap (eye against eye.slash), so it needs an
    /// accessibility value too. Label plus value is the shape `ContentView+SplitLayout`'s link
    /// toggle uses.
    @Test func theHiddenFilesToggleAnnouncesItsState() throws {
        let source = try DashboardSource.read("DashboardViews.swift", atLeast: 5000)
        #expect(source.contains("""
                .accessibilityValue(showHiddenFiles ? "Shown" : "Hidden")
                """.trimmingCharacters(in: .whitespaces)),
                "the hidden-files toggle no longer says whether it is on")
    }
}
