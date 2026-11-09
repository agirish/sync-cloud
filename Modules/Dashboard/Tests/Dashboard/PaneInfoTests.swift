import CoreGraphics
import Foundation
import Testing
import Design
import FileExplorer
import SwiftUI
@testable import Dashboard

/// A pane's Info: its keys, its width, and the line between a column and a drawer.
@Suite struct PaneInfoTests {

    /// Each pane has a switch of its own, and none is a name the retired window-level Info used:
    /// anyone who left `showCompareInspector` on must not find Info open in every pane.
    @Test func everyPaneHasItsOwnKeyAndNoneIsARetiredName() {
        let keys = [PaneInfo.defaultsKey(isLeft: true), PaneInfo.defaultsKey(isLeft: false),
                    PaneInfo.railDefaultsKey, PaneInfo.browseDefaultsKey]
        #expect(Set(keys).count == 4, "two panes share a switch: \(keys)")
        for retired in ["showCompareInspector", "compareInspectorWidth", "infoPreviewMigrationDone"] {
            #expect(!keys.contains(retired), "\(retired) is a retired key and must not come back")
        }
    }

    /// The line is the room Columns needs: it goes to one spanning column under 280, so the column
    /// stack beside Info needs 280, plus Info, its hairline and the stack's trailing gutter. Walked
    /// across Info's whole range, since the line moves with its width.
    @Test func theLineLeavesColumnsTheirOwnMinimumAtEveryWidth() {
        for width in stride(from: PaneInfo.minimumWidth, through: PaneInfo.maximumWidth, by: 50) {
            let needed = 280 + width + 1 + 12
            #expect(PaneInfo.minPaneWidthForColumn(infoWidth: width) >= needed,
                    "Info at \(width) would push Columns into one column")
        }
        #expect(PaneInfo.minPaneWidthForColumn(infoWidth: PaneInfo.defaultWidth) == 600,
                "the line at the default width moved from the 600 the drawer was decided at")
    }

    /// One width for every pane, starting at 300, and kept in range however it was stored: a
    /// hand-edited 50 or 5,000 must not draw an unreadable or pane-wide Info.
    @Test func theWidthStartsAt300AndIsClamped() {
        #expect(PaneInfo.defaultWidth == 300)
        #expect(PaneInfo.clampWidth(50) == PaneInfo.minimumWidth)
        #expect(PaneInfo.clampWidth(5_000) == PaneInfo.maximumWidth)
        #expect(PaneInfo.clampWidth(420) == 420)
        #expect(PaneInfo.minimumWidth == 200 && PaneInfo.maximumWidth == 600)
        #expect(PaneInfo.widthDefaultsKey != PaneViewMode.columnWidthDefaultsKey,
                "Info shares the columns' width key, which the decision (MU) ruled out")
    }

    @Test func offIsOffAtAnyWidth() {
        for width in [0, 250, 600, 1400] as [CGFloat] {
            #expect(PaneInfo.presentation(isOn: false, paneWidth: width, previous: .column) == .off)
        }
    }

    @Test func aWidePaneGetsAColumnAndANarrowOneADrawer() {
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 1089, previous: nil) == .column)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 599, previous: nil) == .drawer)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 600, previous: nil) == .column)
    }

    /// A wider Info needs a wider pane to be a column: at 450 the line is 750.
    @Test func theLineMovesWithInfosWidth() {
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 749, previous: nil, infoWidth: 450) == .drawer)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 750, previous: nil, infoWidth: 450) == .column)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 520, previous: nil, infoWidth: 200) == .column)
    }

    /// A pane sitting on the line does not flip with every point: a drawer becomes a column only 40pt
    /// past it, and a column stays one until it crosses the line. Mutation: dropping the hysteresis
    /// must fail the middle two lines.
    @Test func crossingTheLineHasAHysteresis() {
        let line = PaneInfo.minPaneWidthForColumn(infoWidth: PaneInfo.defaultWidth)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + 20, previous: .drawer) == .drawer)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + PaneInfo.hysteresis, previous: .drawer) == .column)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + 1, previous: .column) == .column)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line - 1, previous: .column) == .drawer)
    }

    /// A drawer is Info's own width, or the pane less a strip of its list, and never under the 200
    /// the details panel needs to reflow cleanly.
    @Test func theDrawerLeavesAStripOfTheListAndKeepsItsFloor() {
        #expect(PaneInfo.drawerWidth(paneWidth: 1000) == 300)
        #expect(PaneInfo.drawerWidth(paneWidth: 1000, infoWidth: 420) == 420)
        #expect(PaneInfo.drawerWidth(paneWidth: 305) == 257)
        #expect(PaneInfo.drawerWidth(paneWidth: 255) == 207)
        #expect(PaneInfo.drawerWidth(paneWidth: 200) == 200)
    }

    // MARK: The column overlay

    private func room(_ edge: PaneInfoSlot.DividerEdge) -> PaneInfoSlot.Room {
        PaneInfoSlot.Room(frame: CGRect(x: 420, y: 0, width: 300, height: 500), hostWidth: 1000,
                          viewport: nil, dividerEdge: edge)
    }

    /// After a column the divider is on Info's trailing edge, so a drag grows Info rightward from
    /// the room's leading edge; at a Tree list's edge the divider is on the leading edge, and Info
    /// grows leftward, keeping its trailing edge on the pane's. Mutation: one rule for both edges
    /// fails one pair.
    @Test func infoGrowsAwayFromTheSideItIsAnchoredTo() {
        #expect(PaneInfoColumnOverlay<EmptyView>.leadingX(room: room(.trailing), width: 400) == 420)
        #expect(PaneInfoColumnOverlay<EmptyView>.leadingX(room: room(.leading), width: 400) == 320)
        #expect(PaneInfoColumnOverlay<EmptyView>.draggedWidth(anchor: 300, translation: 60, edge: .trailing) == 360)
        #expect(PaneInfoColumnOverlay<EmptyView>.draggedWidth(anchor: 300, translation: 60, edge: .leading) == 240)
        #expect(PaneInfoColumnOverlay<EmptyView>.draggedWidth(anchor: 300, translation: -500, edge: .trailing) == 200)
        #expect(PaneInfoColumnOverlay<EmptyView>.draggedWidth(anchor: 300, translation: -500, edge: .leading) == 600)
    }

    /// The action bar centres over what the room leaves of the pane: everything left of Info, and
    /// the whole pane once Info is scrolled out past its edge.
    @Test func theBarKeepsClearOfInfosRoom() {
        #expect(room(.trailing).trailingClearance == 580)
        var scrolledOut = room(.trailing)
        scrolledOut.frame.origin.x = 1100
        #expect(scrolledOut.trailingClearance == 0)
    }
}
