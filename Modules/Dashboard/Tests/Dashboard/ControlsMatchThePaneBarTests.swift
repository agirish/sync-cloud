import AppKit
import SwiftUI
import Testing
import Design
@testable import Dashboard
@testable import FileExplorer

/// The controls that sit on a header line beside the pane bar are drawn at the pane bar's height:
/// Edit's header buttons (`EditorHeaderChipMetrics`), Edit's mode switch and Storage's section bar
/// (`EditorModeBar`), and Organize's rail items (`OrganizeRailMetrics.itemHeight`). Each keeps its
/// own number, in a module that can't see `PaneNavMetrics`; this is the one place that holds them
/// to the pill, so a pill that changes size again takes them with it or fails here.
///
/// At 100%, where "the pane bar's height" is a single number: the pill is fixed, while a glyph that
/// follows the text size may make a switch taller at Large and Largest.
@MainActor
@Suite struct ControlsMatchThePaneBarTests {

    private static var pill: CGFloat { PaneNavMetrics.pill(PaneBarIconSize.regular.ceiling).height }

    private static func height<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.environment(\.appFontScale, 1)).fittingSize.height
    }

    @Test func theConstantsAreThePillsHeight() {
        #expect(EditorHeaderChipMetrics.height == Self.pill)
        #expect(OrganizeRailMetrics.itemHeight == Self.pill)
    }

    /// Drawn, not read: a constant that matches while the view pads around it proves nothing.
    @Test func theDrawnControlsAreThePillsHeight() {
        #expect(Self.height(EditorHeaderChipLabel(symbol: "plus")) == Self.pill, "a bare header button")
        #expect(Self.height(EditorHeaderChipLabel(symbol: "magnifyingglass", word: "Find")) == Self.pill,
                "a worded header button")
        for rung in [EditorModeBar.Rung.labelled, .glyphOnly] {
            #expect(Self.height(EditorModeBar(mode: .constant(.split), accentFill: .blue, onAccent: .white,
                                              forcedRung: rung)) == Self.pill,
                    "Edit's mode switch, \(rung)")
        }
        #expect(Self.height(RailItemLabel(title: "Duplicates", systemImage: "doc.on.doc", state: .reporting(410),
                                          isSelected: true, accent: .blue)) == Self.pill,
                "an Organize rail item")
    }
}
