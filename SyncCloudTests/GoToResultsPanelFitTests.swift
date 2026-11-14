import Testing
import AppKit
import SwiftUI
import Design
import FileExplorer
@testable import SyncCloud

/// The ⌘K list must fit above the window's floor, or it silently loses its top rows:
/// `CommandPalettePanelController.place()` clamps the panel to the host's bottom edge, and
/// `NSHostingView` centres a taller root view, cutting the best rows with the footer; no SwiftUI
/// alignment or `.clipped()` changes AppKit's placement. The room under the field is at least
/// `contentFloor - gapBelowField`. Nothing else would notice a raised `listMaxHeight` or a taller
/// footer.
@MainActor
@Suite(.machinePinned(.layoutMetrics)) struct GoToResultsPanelFitTests {
    /// The surface's height, measured. With more rows than fit, the list is exactly `listMaxHeight`
    /// and the rest is chrome (divider plus the ↑↓ ↩ esc footer).
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

    /// `ContentView`'s window floor, read from source so changing it re-runs the sum below.
    static func contentFloor() throws -> CGFloat {
        let text = try macAppFile("ContentView.swift")
        // Exactly one: `range(of:)` takes the first match, so another `minHeight:` above the window's
        // own frame would silently become the floor.
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
        // Far more rows than fit, so the list sits at its maximum and the rest is chrome.
        let full = Self.measuredSurfaceHeight(rows: 60)
        let chrome = full - GoToResultsPanel.listMaxHeight
        #expect(chrome > 0 && chrome < 200,
                "the surface measured \(full)pt against a \(GoToResultsPanel.listMaxHeight)pt list — the list is not filling its own maximum, so this sum is measuring the wrong thing")
        #expect(full + GoToResultsPanel.gapBelowField <= floor,
                "a full list is \(full)pt plus a \(GoToResultsPanel.gapBelowField)pt gap, against \(floor)pt of window under the toolbar field — on a window at its floor the panel is clamped, and a clamped panel loses its FIRST rows as well as its last")
    }

    /// A taller list must report taller: a `fittingSize` that answers the same number whatever it is
    /// given, as `ScrollView` measurement can, would make the sum above vacuous.
    @Test func theSurfaceReallyGrowsWithItsList() {
        let short = Self.measuredSurfaceHeight(rows: 2)
        let full = Self.measuredSurfaceHeight(rows: 60)
        #expect(short < full,
                "a two-row list and a sixty-row list measure the same height (\(short)pt) — the fit check above is measuring nothing")
        #expect(short > 0)
    }
}
