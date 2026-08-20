import Testing
import AppKit
import SwiftUI
import Design
import FileExplorer
@testable import SyncCloud

/// **The list has to fit above the window's floor, because when it does not the failure is silent
/// and it eats the TOP of the list.**
///
/// `CommandPalettePanelController.place()` clamps the panel to the host's bottom edge. A panel
/// shorter than its content does not crop the bottom: measured 2026-08-19 with a colour ladder,
/// `NSHostingView` **centres** a root view whose ideal height exceeds its bounds, so the
/// highest-ranked rows go along with the footer — and none of `.frame(maxHeight: .infinity,
/// alignment: .top)`, a trailing `Spacer`, a top-aligned `ZStack` or `.clipped()` moves it, because
/// the placement is AppKit's rather than SwiftUI's.
///
/// Today it cannot happen, by about 100pt, and this is the arithmetic that says so:
///
/// - the room under the field is `field.minY - gapBelowField - host.frame.minY`;
/// - the field is a **toolbar** item, so its bottom edge is never below the content's top edge —
///   which makes the room at least `contentFloor - gapBelowField`, with no need to know how tall
///   the toolbar band is;
/// - `contentFloor` is `ContentView`'s own `minHeight`, read out of the source below rather than
///   copied, so changing it re-runs this sum instead of silently invalidating it.
///
/// So this is the guard on a hazard that is currently unreachable, and it is worth having for
/// exactly that reason: raise `listMaxHeight`, or grow the footer, and nothing else in the app
/// reports that ⌘K has started losing its first rows on a short window.
@MainActor
@Suite struct GoToResultsPanelFitTests {

    /// The chrome under the list — divider plus the ↑↓ ↩ esc footer — **measured, not assumed**, by
    /// rendering more rows than the list can show so its own height is exactly `listMaxHeight`.
    static func measuredSurfaceHeight(rows: Int, width: CGFloat = 420) -> CGFloat {
        let list = (0..<rows).map { index in
            PaletteRow(id: "folder.\(index)", group: .folders, title: "Folder \(index)",
                       detail: "Recent · Clients/Folder \(index)", symbol: "folder",
                       route: .folder(path: "/root/Folder \(index)"))
        }
        let view = GoToResultsPanel(rows: list, query: "", selection: .constant(nil),
                                    accent: .blue, glassLevel: .frosted, width: width,
                                    onRun: { _ in }, onHeight: { _ in })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// `ContentView`'s window floor, **read from the source rather than copied**, so changing it
    /// re-runs the sum below instead of quietly invalidating it.
    static func contentFloor() throws -> CGFloat {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ContentView.swift — this sum would be vacuous")
        // **Exactly one, or this is reading somebody else's number.** `range(of:)` takes the first
        // match, so a `minHeight:` added anywhere above the window's own frame would silently
        // become the floor this sum is checked against.
        let count = text.components(separatedBy: "minHeight: ").count - 1
        try #require(count == 1,
                     "ContentView declares \(count) minHeights — this reads the first, which is no longer certainly the window's")
        let marker = try #require(text.range(of: "minHeight: "),
                                  "ContentView no longer declares a minHeight — the window has no floor to measure against")
        let digits = text[marker.upperBound...].prefix { $0.isNumber }
        let value = try #require(Double(String(digits)),
                                 "the minHeight is not a literal number — read it by hand and re-do this sum")
        return CGFloat(value)
    }

    @Test func theWholeListFitsTheShortestWindowThisAppAllows() throws {
        let floor = try Self.contentFloor()
        // Far more rows than the list can show, so its height is pinned at its own maximum and
        // everything above that number is the chrome.
        let full = Self.measuredSurfaceHeight(rows: 60)
        let chrome = full - GoToResultsPanel.listMaxHeight
        #expect(chrome > 0 && chrome < 200,
                "the surface measured \(full)pt against a \(GoToResultsPanel.listMaxHeight)pt list — the list is not filling its own maximum, so this sum is measuring the wrong thing")
        #expect(full + GoToResultsPanel.gapBelowField <= floor,
                "a full list is \(full)pt plus a \(GoToResultsPanel.gapBelowField)pt gap, against \(floor)pt of window under the toolbar field — on a window at its floor the panel is clamped, and a clamped panel loses its FIRST rows as well as its last")
    }

    /// The measurement is only worth something if a taller list really does report taller — a
    /// `fittingSize` that answers the same number whatever it is given would make the sum above
    /// vacuous, which is this repo's own recorded failure mode for `ScrollView` measurement.
    @Test func theSurfaceReallyGrowsWithItsList() {
        let short = Self.measuredSurfaceHeight(rows: 2)
        let full = Self.measuredSurfaceHeight(rows: 60)
        #expect(short < full,
                "a two-row list and a sixty-row list measure the same height (\(short)pt) — the fit check above is measuring nothing")
        #expect(short > 0)
    }
}
