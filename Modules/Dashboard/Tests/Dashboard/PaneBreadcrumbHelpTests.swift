import Foundation
import Testing
@testable import Dashboard

/// A crumb's tooltip offers "both panes" only where there is a second pane. Every workspace but
/// Compare shows one pane, and promising "⌥-click to bring both panes here" (or, with the link
/// preference left on, "panes are linked, so both move here") there is about a pane not on screen.
@Suite struct PaneBreadcrumbHelpTests {

    @Test func onePaneNamesTheDestinationAndNothingElse() {
        for linked in [false, true] {
            #expect(PaneBreadcrumb.crumbHelp(isCurrent: false, helpPath: "Taxes/2025",
                                             linked: linked, hasSecondPane: false)
                    == "Go to Taxes/2025")
            #expect(PaneBreadcrumb.crumbHelp(isCurrent: true, helpPath: "Taxes/2025",
                                             linked: linked, hasSecondPane: false)
                    == "Taxes/2025")
        }
    }

    /// The control: with two panes the both-panes wording is there in both link states, so the test
    /// above isn't passing on a helper that never says it.
    @Test func twoPanesKeepTheBothPanesWording() {
        #expect(PaneBreadcrumb.crumbHelp(isCurrent: false, helpPath: "Taxes", linked: false, hasSecondPane: true)
                == "Go to Taxes — ⌥-click to bring both panes here")
        #expect(PaneBreadcrumb.crumbHelp(isCurrent: false, helpPath: "Taxes", linked: true, hasSecondPane: true)
                == "Go to Taxes — panes are linked, so both move here")
    }

    /// The crumb reads the fact from where it lives: whether the header was handed a both-panes
    /// action. A source scan, because a hosted SwiftUI tree exposes no tooltip under `swift test`
    /// (`EditorRefusalDimTests.theRefusalIsTheRowsTooltip`). Sliced to `crumbButton` so a mention
    /// elsewhere can't stand in.
    @Test func theCrumbAsksWhetherThereIsASecondPane() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/PaneBreadcrumb.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "private func crumbButton("), "crumbButton moved")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "static func crumbHelp("), "crumbHelp moved")
        let body = rest[..<end.lowerBound]
        #expect(body.contains("hasSecondPane: onNavigateBoth != nil"),
                "crumbButton no longer derives the tooltip's second pane from onNavigateBoth")
    }
}
