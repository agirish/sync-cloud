import Foundation
import Testing
@testable import Dashboard

/// **An icon-only button with only a tooltip has no accessible name.**
///
/// On macOS `.help` lands on the accessibility *help*, never the name — a fact this codebase states
/// elsewhere and then did not apply here: nine of the eleven pane-bar rungs were icon-only with a
/// `.help` and nothing else, so Collapse, Back, Forward, New Folder, Sort, Hidden Files, Search, the
/// view-mode menu and ⋯ announced as nothing at all. Scan and Delete were labelled, which is what
/// made it a lapse rather than a policy.
///
/// **A source scan, because the alternative is worse than nothing here.** Assertions against the
/// live accessibility tree pass vacuously with no assistive client attached — this repo has a
/// caption suite that proved it — so a green tree assertion would be evidence of nothing. This
/// counts the modifiers in the file instead, names the file, and fails if it cannot be read.
@Suite struct PaneBarAccessibleNameTests {

    static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                   // …/Tests/Dashboard
            .deletingLastPathComponent()                   // …/Tests
            .deletingLastPathComponent()                   // …/Dashboard (package)
            .appendingPathComponent("Sources/Dashboard/DashboardViews.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Every rung the audit found unnamed, by the name it now answers to.
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

    /// **The state, not just the name.** Hidden Files is a toggle whose on/off rides in a glyph
    /// swap — eye against eye.slash — and was announced only through the tooltip. Label plus value
    /// is the shape `ContentView+SplitLayout`'s link toggle already uses.
    @Test func theHiddenFilesToggleAnnouncesItsState() throws {
        try #require(Self.source.count > 5000)
        #expect(Self.source.contains("""
                .accessibilityValue(showHiddenFiles ? "Shown" : "Hidden")
                """.trimmingCharacters(in: .whitespaces)),
                "the hidden-files toggle no longer says whether it is on")
    }

    /// The count, as an absence: a rung added later with a `.help` and no label would slip past a
    /// list of known names. This says how many labels the file is expected to carry, so adding an
    /// unnamed rung beside them is a failure rather than a silence.
    @Test func noRungWasAddedWithoutAName() throws {
        try #require(Self.source.count > 5000)
        let labels = Self.source.components(separatedBy: ".accessibilityLabel(").count - 1
        #expect(labels >= Self.names.count + 2,
                "expected at least \(Self.names.count + 2) accessible names (the nine repaired rungs plus Scan and Delete); found \(labels)")
    }
}
