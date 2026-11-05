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

    static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/Tests/Dashboard
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/Dashboard (package)
            .appendingPathComponent("Sources/Dashboard/DashboardViews.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// The icon-only rungs, by their accessible names.
    static let names = ["View mode", "Collapse the source pane", "Back", "Forward", "New folder",
                        "Sort", "Search this pane", "More pane options", "Hidden files"]

    @Test func everyIconOnlyPaneBarRungHasAName() throws {
        try #require(Self.source.count > 5000,
                     "DashboardViews.swift could not be read — the scan below would be vacuous")
        for name in Self.names {
            #expect(Self.source.contains(".accessibilityLabel(\"\(name)\")"),
                    "the pane-bar rung named “\(name)” lost its accessible name")
        }
    }

    /// Hidden Files shows its state only by a glyph swap (eye against eye.slash), so it needs an
    /// accessibility value too. Label plus value is the shape `ContentView+SplitLayout`'s link
    /// toggle uses.
    @Test func theHiddenFilesToggleAnnouncesItsState() throws {
        try #require(Self.source.count > 5000)
        #expect(Self.source.contains("""
                .accessibilityValue(showHiddenFiles ? "Shown" : "Hidden")
                """.trimmingCharacters(in: .whitespaces)),
                "the hidden-files toggle no longer says whether it is on")
    }

    /// A new rung with a `.help` and no label would slip past the list of known names, so this also
    /// demands a minimum count of labels: the named rungs plus Scan and Delete.
    @Test func noRungWasAddedWithoutAName() throws {
        try #require(Self.source.count > 5000)
        let labels = Self.source.components(separatedBy: ".accessibilityLabel(").count - 1
        #expect(labels >= Self.names.count + 2,
                "expected at least \(Self.names.count + 2) accessible names (the nine repaired rungs plus Scan and Delete); found \(labels)")
    }
}
